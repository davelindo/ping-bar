import Foundation

final class PingService {
    private let target: String
    private static let timeRegex = try? NSRegularExpression(pattern: "time=(\\d+\\.?\\d*)")

    init(target: String = "google.com") {
        self.target = target
    }

    func executePing() -> Double? {
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
}
