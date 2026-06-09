import Foundation

struct DataUsageTotals: Codable, Equatable, Sendable {
    private(set) var downloaded: UInt64 = 0
    private(set) var uploaded: UInt64 = 0

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

final class DataUsageStore: @unchecked Sendable {
    private static let schemaVersion = 1
    static let defaultRetentionDays = 90

    private struct State: Codable, Sendable {
        var schemaVersion = DataUsageStore.schemaVersion
        var overall = DataUsageTotals()
        var daily: [String: DataUsageTotals] = [:]
        var networks: [String: DataUsageTotals] = [:]
        var networkDaily: [String: [String: DataUsageTotals]] = [:]

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case overall
            case daily
            case networks
            case networkDaily
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? DataUsageStore.schemaVersion
            overall = try container.decodeIfPresent(DataUsageTotals.self, forKey: .overall) ?? DataUsageTotals()
            daily = try container.decodeIfPresent([String: DataUsageTotals].self, forKey: .daily) ?? [:]
            networks = try container.decodeIfPresent([String: DataUsageTotals].self, forKey: .networks) ?? [:]
            networkDaily = try container.decodeIfPresent([String: [String: DataUsageTotals]].self, forKey: .networkDaily) ?? [:]
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let stateQueue = DispatchQueue(label: "com.pingbar.data-usage-store", qos: .utility)
    private let calendar = Calendar(identifier: .gregorian)
    private let saveInterval: TimeInterval = 60
    private let saveByteThreshold: UInt64 = 10 * 1024 * 1024
    private var state: State
    private var lastSave = Date.distantPast
    private var unsavedBytes: UInt64 = 0
    private var retentionDays = DataUsageStore.defaultRetentionDays
    private var lastPrunedDay: String?

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let directory = baseURL.appendingPathComponent("PingBar", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("data-usage.json")
        }

        state = Self.loadState(fileURL: self.fileURL, fileManager: fileManager)
        pruneDailyHistoryLocked(keepingDays: retentionDays, now: Date())
    }

    func setRetentionDays(_ days: Int) {
        let normalized = max(1, days)
        stateQueue.sync {
            guard normalized != retentionDays else { return }
            retentionDays = normalized
            pruneDailyHistoryLocked(keepingDays: normalized, now: Date())
            saveLocked(now: Date(), async: false)
        }
    }

    func record(downloaded: UInt64, uploaded: UInt64, networkName: String?, now: Date = Date()) {
        guard downloaded > 0 || uploaded > 0 else { return }

        stateQueue.sync {
            let day = dayKey(for: now)
            state.overall.add(downloaded: downloaded, uploaded: uploaded)
            state.daily[day, default: DataUsageTotals()].add(downloaded: downloaded, uploaded: uploaded)

            if let name = normalizedNetworkName(networkName) {
                state.networks[name, default: DataUsageTotals()].add(downloaded: downloaded, uploaded: uploaded)
                state.networkDaily[name, default: [:]][day, default: DataUsageTotals()].add(downloaded: downloaded, uploaded: uploaded)
            }

            if lastPrunedDay != day {
                pruneDailyHistoryLocked(keepingDays: retentionDays, now: now)
                lastPrunedDay = day
            }

            let totalDelta = downloaded.saturatingAdd(uploaded)
            unsavedBytes = unsavedBytes.saturatingAdd(totalDelta)
            saveIfNeededLocked(now: now)
        }
    }

    func snapshot(currentNetworkName: String?, now: Date = Date()) -> DataUsageSnapshot {
        stateQueue.sync {
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
    }

    func flush() {
        stateQueue.sync {
            saveLocked(async: false)
        }
    }

    func clear() {
        stateQueue.sync {
            state = State()
            unsavedBytes = 0
            lastPrunedDay = nil
            saveLocked(async: false)
        }
    }

    private static func loadState(fileURL: URL, fileManager: FileManager) -> State {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return State()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(State.self, from: data)
            if decoded.schemaVersion != schemaVersion {
                AppLog.dataUsage.fault("Unsupported usage history schema \(decoded.schemaVersion, privacy: .public); quarantining file")
                quarantineCorruptFile(fileURL: fileURL, fileManager: fileManager)
                return State()
            }
            return decoded
        } catch {
            AppLog.dataUsage.fault("Failed to load usage history; quarantining file: \(error.localizedDescription, privacy: .public)")
            quarantineCorruptFile(fileURL: fileURL, fileManager: fileManager)
            return State()
        }
    }

    private static func quarantineCorruptFile(fileURL: URL, fileManager: FileManager) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: Date())
        let quarantineURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("data-usage.corrupt-\(timestamp).json")

        do {
            if fileManager.fileExists(atPath: quarantineURL.path) {
                try fileManager.removeItem(at: quarantineURL)
            }
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            AppLog.dataUsage.error("Moved corrupt usage history to \(quarantineURL.path, privacy: .private)")
        } catch {
            AppLog.dataUsage.fault("Failed to quarantine corrupt usage history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveIfNeededLocked(now: Date) {
        if now.timeIntervalSince(lastSave) >= saveInterval || unsavedBytes >= saveByteThreshold {
            saveLocked(now: now)
        }
    }

    private func saveLocked(now: Date = Date(), async: Bool = true) {
        let fileURL = fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        let fileManager = SendableFileManager(fileManager)
        let state = state
        let pendingBytes = unsavedBytes
        let write: @Sendable () -> Void = {
            guard Self.writeState(state, to: fileURL, directoryURL: directoryURL, fileManager: fileManager.value) else {
                return
            }
            self.lastSave = now
            self.unsavedBytes = self.unsavedBytes >= pendingBytes ? self.unsavedBytes - pendingBytes : 0
        }

        if async {
            stateQueue.async(execute: write)
        } else {
            write()
        }
    }

    private static func writeState(_ state: State, to fileURL: URL, directoryURL: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            AppLog.dataUsage.error("Failed to save usage history: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func rebuildNetworkTotalsFromDailyLocked() {
        state.networks = state.networkDaily.mapValues { daily in
            daily.values.reduce(into: DataUsageTotals()) { totals, dayTotals in
                totals.add(downloaded: dayTotals.downloaded, uploaded: dayTotals.uploaded)
            }
        }
        state.networks = state.networks.filter { $0.value.total > 0 }
    }

    private func pruneDailyHistoryLocked(keepingDays days: Int, now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -days + 1, to: now) else { return }
        let cutoffKey = dayKey(for: cutoff)
        state.daily = state.daily.filter { $0.key >= cutoffKey }
        state.networkDaily = state.networkDaily.compactMapValues { daily in
            let pruned = daily.filter { $0.key >= cutoffKey }
            return pruned.isEmpty ? nil : pruned
        }
        rebuildNetworkTotalsFromDailyLocked()
    }

    func dayKey(for date: Date) -> String {
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

private struct SendableFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
