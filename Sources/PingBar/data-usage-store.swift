import Foundation

struct DataUsageTotals: Codable, Equatable, Sendable {
    var downloaded: UInt64 = 0
    var uploaded: UInt64 = 0

    var total: UInt64 {
        downloaded.saturatingAdd(uploaded)
    }

    mutating func add(downloaded down: UInt64, uploaded up: UInt64) {
        downloaded = downloaded.saturatingAdd(down)
        uploaded = uploaded.saturatingAdd(up)
    }
}

struct DataUsageNetworkRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let totals: DataUsageTotals
}

struct DataUsageDailyRecord: Equatable, Identifiable, Sendable {
    var id: String {
        "\(day)|\(networkName ?? "all")"
    }

    let day: String
    let networkName: String?
    let totals: DataUsageTotals
}

struct DataUsageSnapshot: Equatable, Sendable {
    var overall = DataUsageTotals()
    var today = DataUsageTotals()
    var currentNetworkName: String?
    var currentNetworkTotals: DataUsageTotals?
    var networks: [DataUsageNetworkRecord] = []
    var overallDailyRecords: [DataUsageDailyRecord] = []
    var networkDailyRecords: [DataUsageDailyRecord] = []
    var retentionDays: Int = DataUsageStore.defaultRetentionDays
}

final class DataUsageStore {
    static let defaultRetentionDays = 90

    private struct State: Codable, Sendable {
        var overall = DataUsageTotals()
        var daily: [String: DataUsageTotals] = [:]
        var networks: [String: DataUsageTotals] = [:]
        var networkDaily: [String: [String: DataUsageTotals]] = [:]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let writeQueue = DispatchQueue(label: "com.pingbar.data-usage-store", qos: .utility)
    private let calendar = Calendar(identifier: .gregorian)
    private let saveInterval: TimeInterval = 60
    private let saveByteThreshold: UInt64 = 10 * 1024 * 1024
    private var state: State
    private var lastSave = Date.distantPast
    private var unsavedBytes: UInt64 = 0
    private var retentionDays = DataUsageStore.defaultRetentionDays
    private var lastPrunedDay: String?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = baseURL.appendingPathComponent("PingBar", isDirectory: true)
        fileURL = directory.appendingPathComponent("data-usage.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
        pruneDailyHistory(keepingDays: retentionDays, now: Date())
    }

    func setRetentionDays(_ days: Int) {
        let normalized = max(1, days)
        guard normalized != retentionDays else { return }
        retentionDays = normalized
        pruneDailyHistory(keepingDays: normalized, now: Date())
        save()
    }

    func record(downloaded: UInt64, uploaded: UInt64, networkName: String?, now: Date = Date()) {
        guard downloaded > 0 || uploaded > 0 else { return }

        let day = dayKey(for: now)
        state.overall.add(downloaded: downloaded, uploaded: uploaded)
        state.daily[day, default: DataUsageTotals()].add(downloaded: downloaded, uploaded: uploaded)

        if let name = normalizedNetworkName(networkName) {
            state.networks[name, default: DataUsageTotals()].add(downloaded: downloaded, uploaded: uploaded)
            state.networkDaily[name, default: [:]][day, default: DataUsageTotals()].add(downloaded: downloaded, uploaded: uploaded)
        }

        if lastPrunedDay != day {
            pruneDailyHistory(keepingDays: retentionDays, now: now)
            lastPrunedDay = day
        }

        let totalDelta = downloaded.saturatingAdd(uploaded)
        unsavedBytes = unsavedBytes.saturatingAdd(totalDelta)
        saveIfNeeded(now: now)
    }

    func snapshot(currentNetworkName: String?, now: Date = Date()) -> DataUsageSnapshot {
        let name = normalizedNetworkName(currentNetworkName)
        let networks = state.networks
            .map { DataUsageNetworkRecord(name: $0.key, totals: $0.value) }
            .sorted {
                if $0.totals.total == $1.totals.total {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.totals.total > $1.totals.total
            }
        let overallDailyRecords = state.daily.map { day, totals in
            DataUsageDailyRecord(day: day, networkName: nil, totals: totals)
        }
        .sorted {
            $0.day > $1.day
        }
        let networkDailyRecords = state.networkDaily.flatMap { networkName, daily in
            daily.map { day, totals in
                DataUsageDailyRecord(day: day, networkName: networkName, totals: totals)
            }
        }
        .sorted {
            if $0.day == $1.day {
                if $0.totals.total == $1.totals.total {
                    return ($0.networkName ?? "").localizedCaseInsensitiveCompare($1.networkName ?? "") == .orderedAscending
                }
                return $0.totals.total > $1.totals.total
            }
            return $0.day > $1.day
        }

        return DataUsageSnapshot(
            overall: state.overall,
            today: state.daily[dayKey(for: now)] ?? DataUsageTotals(),
            currentNetworkName: name,
            currentNetworkTotals: name.flatMap { state.networks[$0] },
            networks: networks,
            overallDailyRecords: overallDailyRecords,
            networkDailyRecords: networkDailyRecords,
            retentionDays: retentionDays
        )
    }

    func flush() {
        save(async: false)
    }

    func clear() {
        state = State()
        unsavedBytes = 0
        lastPrunedDay = nil
        save(async: false)
    }

    private func saveIfNeeded(now: Date) {
        if now.timeIntervalSince(lastSave) >= saveInterval || unsavedBytes >= saveByteThreshold {
            save(now: now)
        }
    }

    private func save(now: Date = Date(), async: Bool = true) {
        let fileURL = fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        let fileManager = SendableFileManager(fileManager)
        let state = state
        let write: @Sendable () -> Void = {
            do {
                try fileManager.value.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.value.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(state)
                try data.write(to: fileURL, options: .atomic)
                try fileManager.value.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                // Usage history is non-critical; skip this save and retry on the next scheduled flush.
            }
        }

        if async {
            writeQueue.async(execute: write)
        } else {
            writeQueue.sync(execute: write)
        }
        lastSave = now
        unsavedBytes = 0
    }

    private func rebuildNetworkTotalsFromDaily() {
        state.networks = state.networkDaily.mapValues { daily in
            daily.values.reduce(into: DataUsageTotals()) { totals, dayTotals in
                totals.add(downloaded: dayTotals.downloaded, uploaded: dayTotals.uploaded)
            }
        }
        state.networks = state.networks.filter { $0.value.total > 0 }
    }

    private func pruneDailyHistory(keepingDays days: Int, now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -days + 1, to: now) else { return }
        let cutoffKey = dayKey(for: cutoff)
        state.daily = state.daily.filter { $0.key >= cutoffKey }
        state.networkDaily = state.networkDaily.compactMapValues { daily in
            let pruned = daily.filter { $0.key >= cutoffKey }
            return pruned.isEmpty ? nil : pruned
        }
        rebuildNetworkTotalsFromDaily()
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func normalizedNetworkName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 {
        let result = addingReportingOverflow(value)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

private struct SendableFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
