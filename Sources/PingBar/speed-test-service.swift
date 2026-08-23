import Foundation

enum LagRating: Sendable {
    case low
    case moderate
    case high
    case unknown

    var label: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .unknown: return "Unknown"
        }
    }
}

struct SpeedTestResult: Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    let idleLatencyMs: Double?
    let loadedLatencyMs: Double?
    let responsiveness: Double?
    let provider: String
    let endpoint: String?
    let timestamp: Date
    let lagRating: LagRating
}

enum SpeedTestState: Sendable {
    case idle
    case running(SpeedTestPhase)
    case completed(SpeedTestResult)
    case failed(String)
    case cancelled
}

enum SpeedTestPhase: String, Sendable {
    case preparing = "Preparing..."
    case downloading = "Downloading..."
    case uploading = "Uploading..."
    case finishing = "Finishing..."
}

enum SpeedTestError: Error, CustomStringConvertible, Sendable {
    case cancelled
    case failed(String)

    var description: String {
        switch self {
        case .cancelled: return "cancelled"
        case .failed(let message): return message
        }
    }
}

final class SpeedTestService: @unchecked Sendable {
    private struct RunState {
        var activeRunID: UUID?
        var isCancelled = false
        var isFinishing = false
        var downloadTask: URLSessionDataTask?
        var uploadTask: URLSessionDataTask?
        var pingStopSemaphore: DispatchSemaphore?
    }

    private let stateLock = NSLock()
    private var runState = RunState()
    private let session = URLSession(configuration: .ephemeral)
    private let latencyOperation: @Sendable (String?, Int) -> Double?
    private static let transferTimeout: TimeInterval = 20.0

    init(latencyOperation: @escaping @Sendable (String?, Int) -> Double? = { host, samples in
        SpeedTestService.measureLatency(host: host, samples: samples)
    }) {
        self.latencyOperation = latencyOperation
    }

    func run(
        routerHost: String?,
        phase: @escaping @MainActor @Sendable (SpeedTestPhase) -> Void,
        completion: @escaping @MainActor @Sendable (Result<SpeedTestResult, SpeedTestError>) -> Void
    ) {
        stateLock.lock()
        guard runState.activeRunID == nil else {
            stateLock.unlock()
            return
        }

        let runID = UUID()
        runState.activeRunID = runID
        runState.isCancelled = false
        runState.isFinishing = false
        runState.downloadTask = nil
        runState.uploadTask = nil
        runState.pingStopSemaphore = nil
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard self.isCurrentRun(runID) else {
                self.finishAndDeliver(runID, .failure(.cancelled), completion)
                return
            }

            Task { @MainActor in phase(.preparing) }
            let idleLatency = self.latencyOperation(routerHost, 3)

            if self.isRunCancelled() {
                self.finishAndDeliver(runID, .failure(.cancelled), completion)
                return
            }

            Task { @MainActor in phase(.downloading) }
            guard let downloadMbps = self.performDownload(bytes: 20_000_000) else {
                if self.isRunCancelled() {
                    self.finishAndDeliver(runID, .failure(.cancelled), completion)
                } else {
                    self.finishAndDeliver(runID, .failure(.failed("Download test failed")), completion)
                }
                return
            }

            if self.isRunCancelled() {
                self.finishAndDeliver(runID, .failure(.cancelled), completion)
                return
            }

            guard self.isCurrentRun(runID) else {
                self.finishAndDeliver(runID, .failure(.cancelled), completion)
                return
            }

            Task { @MainActor in phase(.uploading) }
            let loadedSamples = LockedDoubleSamples()
            let pingService = routerHost.map { PingService(target: $0) }
            let stopSemaphore = DispatchSemaphore(value: 0)
            self.stateLock.lock()
            self.runState.pingStopSemaphore = stopSemaphore
            self.stateLock.unlock()
            DispatchQueue.global(qos: .background).async {
                while !self.isRunCancelled() {
                    if stopSemaphore.wait(timeout: .now()) == .success {
                        break
                    }
                    if let ping = pingService?.executePing() {
                        loadedSamples.append(ping)
                    }
                    if self.waitForPingIntervalOrCancellation(on: stopSemaphore) {
                        break
                    }
                }
            }

            let uploadMbps = self.performUpload(bytes: 5_000_000)
            stopSemaphore.signal()

            if self.isRunCancelled() {
                self.finishAndDeliver(runID, .failure(.cancelled), completion)
                return
            }

            guard let uploadMbps else {
                self.finishAndDeliver(runID, .failure(.failed("Upload test failed")), completion)
                return
            }

            Task { @MainActor in phase(.finishing) }
            let loadedLatency = self.percentile(loadedSamples.snapshot(), 0.9)
            let lagRating = self.evaluateLag(idle: idleLatency, loaded: loadedLatency, responsiveness: nil)

            let result = SpeedTestResult(
                downloadMbps: downloadMbps,
                uploadMbps: uploadMbps,
                idleLatencyMs: idleLatency,
                loadedLatencyMs: loadedLatency,
                responsiveness: nil,
                provider: "Cloudflare",
                endpoint: "speed.cloudflare.com",
                timestamp: Date(),
                lagRating: lagRating
            )

            self.finishAndDeliver(runID, .success(result), completion)
        }
    }

    private func isCurrentRun(_ identifier: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runState.activeRunID == identifier && !runState.isCancelled
    }

    func cancel() {
        stateLock.lock()
        runState.isCancelled = true
        let semaphore = runState.pingStopSemaphore
        runState.downloadTask?.cancel()
        runState.uploadTask?.cancel()
        runState.downloadTask = nil
        runState.uploadTask = nil
        stateLock.unlock()
        semaphore?.signal()
    }

    private func finishAndDeliver(
        _ identifier: UUID,
        _ outcome: Result<SpeedTestResult, SpeedTestError>,
        _ completion: @escaping @MainActor @Sendable (Result<SpeedTestResult, SpeedTestError>) -> Void
    ) {
        stateLock.lock()
        let shouldDeliver = runState.activeRunID == identifier && !runState.isFinishing
        if shouldDeliver {
            runState.isFinishing = true
            runState.activeRunID = nil
            runState.isCancelled = false
            runState.downloadTask = nil
            runState.uploadTask = nil
            runState.pingStopSemaphore = nil
        }
        stateLock.unlock()

        guard shouldDeliver else { return }
        Task { @MainActor in completion(outcome) }
    }

    private func isRunCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runState.isCancelled
    }

    private func waitForPingIntervalOrCancellation(on semaphore: DispatchSemaphore) -> Bool {
        let result = semaphore.wait(timeout: .now() + 0.8)
        return result == .success
    }

    private func performDownload(bytes: Int) -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.transferTimeout
        let start = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        let result = URLTransferResult()
        let task = session.dataTask(with: request) { data, response, error in

            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let responseData = data else {
                AppLog.speedTest.error("Download test failed: \(error?.localizedDescription ?? "invalid response", privacy: .public)")
                return
            }
            guard result.snapshot().bytes + responseData.count <= bytes else {
                AppLog.speedTest.error("Download test returned more than \(bytes, privacy: .public) bytes")
                return
            }
            result.succeed(bytes: result.snapshot().bytes + responseData.count)
        }
        stateLock.lock()
        runState.downloadTask = task
        stateLock.unlock()
        task.resume()
        _ = semaphore.wait(timeout: .now() + Self.transferTimeout + 2.0)
        if isRunCancelled() || result.snapshot().success == false {
            task.cancel()
        }
        stateLock.lock()
        if runState.downloadTask === task {
            runState.downloadTask = nil
        }
        stateLock.unlock()

        let outcome = result.snapshot()
        let success = outcome.success
        let downloadedBytes = outcome.bytes
        guard success, downloadedBytes == bytes else {
            if success, downloadedBytes != bytes {
                AppLog.speedTest.error("Download test returned \(downloadedBytes, privacy: .public) bytes, expected \(bytes, privacy: .public)")
            }
            return nil
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard elapsed > 0 else { return nil }
        return (Double(downloadedBytes) * 8) / elapsed / 1_000_000
    }

    private func performUpload(bytes: Int) -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.transferTimeout
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pingbar-upload-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            AppLog.speedTest.error("Could not create temporary upload file")
            return nil
        }

        guard let bodyHandle = try? FileHandle(forWritingTo: bodyURL) else {
            AppLog.speedTest.error("Could not open temporary upload file")
            return nil
        }
        do {
            try bodyHandle.truncate(atOffset: UInt64(bytes))
            try bodyHandle.close()
        } catch {
            try? bodyHandle.close()
            try? FileManager.default.removeItem(at: bodyURL)
            AppLog.speedTest.error("Could not size temporary upload file: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let start = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        let result = URLTransferResult()

        let task = session.uploadTask(with: request, fromFile: bodyURL) { _, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                AppLog.speedTest.error("Upload test failed: \(error?.localizedDescription ?? "invalid response", privacy: .public)")
                return
            }
            result.succeed(bytes: bytes)
        }
        stateLock.lock()
        runState.uploadTask = task
        stateLock.unlock()
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + Self.transferTimeout + 2.0)
        if waitResult == .timedOut {
            task.cancel()
        }
        stateLock.lock()
        if runState.uploadTask === task {
            runState.uploadTask = nil
        }
        stateLock.unlock()
        try? FileManager.default.removeItem(at: bodyURL)

        guard waitResult == .success else {
            AppLog.speedTest.error("Upload test callback timed out")
            return nil
        }

        let success = result.snapshot().success
        guard success else { return nil }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard elapsed > 0 else { return nil }
        return (Double(bytes) * 8) / elapsed / 1_000_000
    }

    private static func measureLatency(host: String?, samples: Int) -> Double? {
        guard let host, samples > 0 else { return nil }
        let pingService = PingService(target: host)
        var values: [Double] = []
        for _ in 0..<samples {
            if let value = pingService.executePing() {
                values.append(value)
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func evaluateLag(idle: Double?, loaded: Double?, responsiveness: Double?) -> LagRating {
        if let idle = idle, let loaded = loaded {
            let delta = loaded - idle
            if delta < 30 { return .low }
            if delta < 80 { return .moderate }
            return .high
        }
        if let rpm = responsiveness {
            if rpm >= 200 { return .low }
            if rpm >= 100 { return .moderate }
            return .high
        }
        return .unknown
    }
}

private final class LockedDoubleSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class URLTransferResult: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var success = false

    func succeed(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.bytes = bytes
        success = true
    }

    func snapshot() -> (bytes: Int, success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes: bytes, success: success)
    }
}
