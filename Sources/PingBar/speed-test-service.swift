import Foundation

enum LagRating {
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

struct SpeedTestResult {
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

enum SpeedTestState {
    case idle
    case running(SpeedTestPhase)
    case completed(SpeedTestResult)
    case failed(String)
    case cancelled
}

enum SpeedTestPhase: String {
    case preparing = "Preparing..."
    case downloading = "Downloading..."
    case uploading = "Uploading..."
    case finishing = "Finishing..."
}

enum SpeedTestError: Error, CustomStringConvertible {
    case cancelled
    case failed(String)

    var description: String {
        switch self {
        case .cancelled: return "cancelled"
        case .failed(let message): return message
        }
    }
}

final class SpeedTestService {
    private var downloadTask: URLSessionDataTask?
    private var uploadTask: URLSessionDataTask?
    private var isCancelled = false
    private let session = URLSession(configuration: .ephemeral)

    func run(routerHost: String?, phase: @escaping (SpeedTestPhase) -> Void, completion: @escaping (Result<SpeedTestResult, SpeedTestError>) -> Void) {
        guard downloadTask == nil, uploadTask == nil else { return }
        isCancelled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { phase(.preparing) }
            let idleLatency = self.measureLatency(host: routerHost, samples: 3)

            DispatchQueue.main.async { phase(.downloading) }
            guard let downloadMbps = self.performDownload(bytes: 20_000_000) else {
                self.finishIfCancelled(completion: completion)
                DispatchQueue.main.async {
                    completion(.failure(.failed("Download test failed")))
                }
                return
            }

            if self.isCancelled {
                self.finishIfCancelled(completion: completion)
                return
            }

            DispatchQueue.main.async { phase(.uploading) }
            var loadedSamples: [Double] = []
            let samplesQueue = DispatchQueue(label: "speedtest.loadedSamples")
            let pingService = routerHost.map { PingService(target: $0) }
            let stopSemaphore = DispatchSemaphore(value: 0)
            let pingWorker = DispatchQueue.global(qos: .background)
            pingWorker.async {
                while !self.isCancelled {
                    if stopSemaphore.wait(timeout: .now()) == .success {
                        break
                    }
                    if let ping = pingService?.executePing() {
                        samplesQueue.async {
                            loadedSamples.append(ping)
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.8)
                }
            }

            let uploadMbps = self.performUpload(bytes: 5_000_000)
            stopSemaphore.signal()

            if self.isCancelled {
                self.finishIfCancelled(completion: completion)
                return
            }

            guard let uploadMbps else {
                DispatchQueue.main.async {
                    completion(.failure(.failed("Upload test failed")))
                }
                return
            }

            DispatchQueue.main.async { phase(.finishing) }
            let loadedLatency = samplesQueue.sync {
                self.percentile(loadedSamples, 0.9)
            }
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

            DispatchQueue.main.async {
                completion(.success(result))
            }
        }
    }

    func cancel() {
        isCancelled = true
        downloadTask?.cancel()
        uploadTask?.cancel()
        downloadTask = nil
        uploadTask = nil
    }

    private func finishIfCancelled(completion: @escaping (Result<SpeedTestResult, SpeedTestError>) -> Void) {
        if isCancelled {
            DispatchQueue.main.async {
                completion(.failure(.cancelled))
            }
        }
    }

    private func performDownload(bytes: Int) -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        var downloadedBytes: Int = 0
        var success = false

        downloadTask = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data = data else {
                return
            }
            downloadedBytes = data.count
            success = true
        }
        downloadTask?.resume()
        semaphore.wait()
        downloadTask = nil

        guard success else { return nil }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard elapsed > 0 else { return nil }
        return (Double(downloadedBytes) * 8) / elapsed / 1_000_000
    }

    private func performUpload(bytes: Int) -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let payload = Data(count: bytes)
        let start = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        uploadTask = session.uploadTask(with: request, from: payload) { _, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }
            success = true
        }
        uploadTask?.resume()
        semaphore.wait()
        uploadTask = nil

        guard success else { return nil }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard elapsed > 0 else { return nil }
        return (Double(bytes) * 8) / elapsed / 1_000_000
    }

    private func measureLatency(host: String?, samples: Int) -> Double? {
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
