import Foundation

final class SettingsStore: ObservableObject {
    private enum Keys {
        static let internetPingTarget = "settings.internetPingTarget"
        static let dnsLookupHost = "settings.dnsLookupHost"
        static let samplingIntervalOpen = "settings.samplingIntervalOpen"
        static let samplingIntervalClosed = "settings.samplingIntervalClosed"
        static let statusBarDisplayMode = "settings.statusBarDisplayMode"
    }

    static let defaultInternetPingTarget = "1.1.1.1"
    static let defaultDnsLookupHost = "cloudflare.com"
    static let defaultSamplingIntervalOpen = 1.0
    static let defaultSamplingIntervalClosed = 10.0

    private let defaults: UserDefaults

    @Published var statusBarDisplayMode: StatusBarDisplayMode {
        didSet { defaults.set(statusBarDisplayMode.rawValue, forKey: Keys.statusBarDisplayMode) }
    }

    @Published var internetPingTarget: String {
        didSet { normalizeAndSaveInternetTarget() }
    }

    @Published var dnsLookupHost: String {
        didSet { normalizeAndSaveDnsHost() }
    }

    @Published var samplingIntervalOpen: Double {
        didSet { normalizeAndSaveSamplingIntervalOpen() }
    }

    @Published var samplingIntervalClosed: Double {
        didSet { normalizeAndSaveSamplingIntervalClosed() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        internetPingTarget = defaults.string(forKey: Keys.internetPingTarget) ?? Self.defaultInternetPingTarget
        dnsLookupHost = defaults.string(forKey: Keys.dnsLookupHost) ?? Self.defaultDnsLookupHost
        samplingIntervalOpen = defaults.object(forKey: Keys.samplingIntervalOpen) as? Double ?? Self.defaultSamplingIntervalOpen
        samplingIntervalClosed = defaults.object(forKey: Keys.samplingIntervalClosed) as? Double ?? Self.defaultSamplingIntervalClosed
        if let rawValue = defaults.string(forKey: Keys.statusBarDisplayMode),
           let mode = StatusBarDisplayMode(rawValue: rawValue) {
            statusBarDisplayMode = mode
        } else {
            statusBarDisplayMode = .latency
        }

        normalizeAndSaveInternetTarget()
        normalizeAndSaveDnsHost()
        normalizeAndSaveSamplingIntervalOpen()
        normalizeAndSaveSamplingIntervalClosed()
    }

    private func normalizeAndSaveInternetTarget() {
        let normalized = normalizedHost(internetPingTarget, defaultValue: Self.defaultInternetPingTarget)
        if internetPingTarget != normalized {
            internetPingTarget = normalized
            return
        }
        defaults.set(normalized, forKey: Keys.internetPingTarget)
    }

    private func normalizeAndSaveDnsHost() {
        let normalized = normalizedHost(dnsLookupHost, defaultValue: Self.defaultDnsLookupHost)
        if dnsLookupHost != normalized {
            dnsLookupHost = normalized
            return
        }
        defaults.set(normalized, forKey: Keys.dnsLookupHost)
    }

    private func normalizeAndSaveSamplingIntervalOpen() {
        let normalized = normalizedInterval(samplingIntervalOpen, defaultValue: Self.defaultSamplingIntervalOpen)
        if samplingIntervalOpen != normalized {
            samplingIntervalOpen = normalized
            return
        }
        defaults.set(normalized, forKey: Keys.samplingIntervalOpen)
    }

    private func normalizeAndSaveSamplingIntervalClosed() {
        let normalized = normalizedInterval(samplingIntervalClosed, defaultValue: Self.defaultSamplingIntervalClosed)
        if samplingIntervalClosed != normalized {
            samplingIntervalClosed = normalized
            return
        }
        defaults.set(normalized, forKey: Keys.samplingIntervalClosed)
    }

    private func normalizedHost(_ value: String, defaultValue: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    private func normalizedInterval(_ value: Double, defaultValue: Double) -> Double {
        let clamped = max(0.5, value)
        return clamped.isNaN ? defaultValue : clamped
    }
}

enum StatusBarDisplayMode: String, CaseIterable, Identifiable {
    case latency
    case throughput

    var id: String { rawValue }

    var label: String {
        switch self {
        case .latency:
            return "Latency"
        case .throughput:
            return "Up/Down"
        }
    }
}
