import OSLog

enum AppLog {
    private static let subsystem = "com.elitan.pingbar"

    static let captivePortal = Logger(subsystem: subsystem, category: "captive-portal")
    static let dataUsage = Logger(subsystem: subsystem, category: "data-usage")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    static let ping = Logger(subsystem: subsystem, category: "ping")
    static let speedTest = Logger(subsystem: subsystem, category: "speed-test")
    static let throughput = Logger(subsystem: subsystem, category: "throughput")
}
