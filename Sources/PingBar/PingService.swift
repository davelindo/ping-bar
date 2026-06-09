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
        process.arguments = ["-c", "1", "-t", "2", target]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        guard let regex = Self.timeRegex,
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }

        return Double(output[range])
    }

    private func executeTCPConnect(port: UInt16) -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let start = Date()
        let connection = NWConnection(host: NWEndpoint.Host(target), port: nwPort, using: .tcp)
        let probe = TCPConnectProbe(connection: connection, semaphore: semaphore)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                probe.finish(Date().timeIntervalSince(start) * 1000)
            case .failed, .cancelled:
                probe.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))

        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            probe.finish(nil)
        }

        return probe.elapsed()
    }
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
        let value = value
        return value
    }
}
