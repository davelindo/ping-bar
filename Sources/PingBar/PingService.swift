import Darwin
import Foundation
import Network

final class PingService: Sendable {
    enum Backend: Sendable {
        case systemPing
        case tcpConnect(port: UInt16)
    }

    private let target: String
    private let backend: Backend
    private static let timeRegex = try? NSRegularExpression(pattern: "time=(\\d+\\.?\\d*)")
    private static let systemPingTimeout: TimeInterval = 1.0

    init(target: String = "google.com", backend: Backend = .systemPing) {
        self.target = target
        self.backend = backend
    }

    func executePing() -> Double? {
        switch backend {
        case .systemPing:
            return executeSystemPing()
        case .tcpConnect(let port):
            return executeTCPConnect(port: port)
        }
    }

    private func executeSystemPing() -> Double? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = [
            "-c", "1",
            "-W", String(Int(Self.systemPingTimeout * 1000)),
            "-t", String(Int(Self.systemPingTimeout)),
            target
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            AppLog.ping.error("Failed to launch /sbin/ping for \(self.target, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let outputBox = PingOutputBox()
        DispatchQueue.global(qos: .background).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            outputBox.data = data
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + Self.systemPingTimeout) == .success else {
            process.terminate()
            if semaphore.wait(timeout: .now() + 0.2) == .timedOut {
                process.interrupt()
                _ = semaphore.wait(timeout: .now() + 0.2)
            }
            AppLog.ping.error("System ping fallback to \(self.target, privacy: .public) timed out")
            return nil
        }

        guard process.terminationStatus == 0 else {
            AppLog.ping.error("System ping fallback to \(self.target, privacy: .public) exited with status \(process.terminationStatus, privacy: .public)")
            return nil
        }

        guard let output = String(data: outputBox.data, encoding: .utf8),
              let latency = Self.latency(from: output) else {
            AppLog.ping.error("System ping fallback to \(self.target, privacy: .public) returned no latency sample")
            return nil
        }

        return latency
    }

    static func latency(from output: String) -> Double? {
        guard let regex = Self.timeRegex,
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }

        return Double(output[range])
    }

    private func executeTCPConnect(port: UInt16) -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            AppLog.ping.error("Invalid TCP probe port \(port, privacy: .public) for \(self.target, privacy: .public)")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let start = Date()
        let connection = NWConnection(host: NWEndpoint.Host(target), port: nwPort, using: .tcp)
        let probe = TCPConnectProbe(connection: connection, semaphore: semaphore)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                probe.finish(Date().timeIntervalSince(start) * 1000)
            case .waiting(let error):
                AppLog.ping.error("TCP probe to \(self.target, privacy: .public):\(port, privacy: .public) waiting: \(String(describing: error), privacy: .public)")
                probe.finish(nil)
            case .failed(let error):
                AppLog.ping.error("TCP probe to \(self.target, privacy: .public):\(port, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                probe.finish(nil)
            case .cancelled:
                probe.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))

        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            AppLog.ping.error("TCP probe to \(self.target, privacy: .public):\(port, privacy: .public) timed out")
            probe.finish(nil)
        }

        return probe.elapsed()
    }
}

private final class PingOutputBox: @unchecked Sendable {
    var data = Data()
}

private final class TCPConnectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let semaphore: DispatchSemaphore
    private var completed = false
    private var value: Double?

    init(connection: NWConnection, semaphore: DispatchSemaphore) {
        self.connection = connection
        self.semaphore = semaphore
    }

    func finish(_ value: Double?) {
        let shouldFinish: Bool
        lock.lock()
        if completed {
            shouldFinish = false
        } else {
            completed = true
            self.value = value
            shouldFinish = true
        }
        lock.unlock()

        guard shouldFinish else { return }
        connection.cancel()
        semaphore.signal()
    }

    func elapsed() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
