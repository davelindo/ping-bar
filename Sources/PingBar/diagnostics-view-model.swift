import Foundation
import SwiftUI
import AppKit

enum ConnectionStatus {
    case connected
    case limited
    case offline

    var color: Color {
        switch self {
        case .connected: return .green
        case .limited: return .orange
        case .offline: return .red
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .limited: return "Limited"
        case .offline: return "Offline"
        }
    }
}

enum MetricStatus {
    case good
    case warning
    case bad
}

enum ActiveConnectionType: Equatable {
    case wifi
    case ethernet
    case thunderbolt
    case other(String?)
}

struct DiagnosticsSnapshot: Equatable {
    var wifiInfo: WiFiInfo?
    var routerLatency: Double?
    var internetLatency: Double?
    var dnsLatency: Double?
    var routerHistory: [Double?] = []
    var internetHistory: [Double?] = []
    var dnsHistory: [Double?] = []
    var wifiSignalHistory: [Double?] = []
    var wifiNoiseHistory: [Double?] = []
    var wifiRateHistory: [Double?] = []
    var routerJitterHistory: [Double?] = []
    var internetJitterHistory: [Double?] = []
    var routerLossHistory: [Double?] = []
    var internetLossHistory: [Double?] = []
    var downloadRateHistory: [Double?] = []
    var uploadRateHistory: [Double?] = []
    var routerJitter: Double?
    var internetJitter: Double?
    var routerLoss: Double = 0
    var internetLoss: Double = 0
    var isRunning: Bool = false
    var gatewayIP: String?
    var captivePortalStatus: CaptivePortalStatus = .unknown
    var dnsServers: [String] = []
    var hasLocationPermission: Bool = false
    var defaultRouteInterface: String?
    var defaultRoutePortName: String?
    var currentDownloadRate: Double?
    var currentUploadRate: Double?
    var totalDownloaded: Double?
    var totalUploaded: Double?
    var dataUsage = DataUsageSnapshot()
}

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    private let service: DiagnosticsService
    private let speedTestService = SpeedTestService()

    @Published var speedTestState: SpeedTestState = .idle
    @Published var isPopoverVisible: Bool = false
    @Published private(set) var snapshot = DiagnosticsSnapshot()

    init(service: DiagnosticsService) {
        self.service = service
    }

    func refresh() {
        let newSnapshot = DiagnosticsSnapshot(
            wifiInfo: service.wifiInfo,
            routerLatency: service.routerHistory.latest,
            internetLatency: service.internetHistory.latest,
            dnsLatency: service.dnsHistory.latest,
            routerHistory: service.routerHistory.values,
            internetHistory: service.internetHistory.values,
            dnsHistory: service.dnsHistory.values,
            wifiSignalHistory: service.wifiSignalHistory.values,
            wifiNoiseHistory: service.wifiNoiseHistory.values,
            wifiRateHistory: service.wifiRateHistory.values,
            routerJitterHistory: service.routerJitterHistory.values,
            internetJitterHistory: service.internetJitterHistory.values,
            routerLossHistory: service.routerLossHistory.values,
            internetLossHistory: service.internetLossHistory.values,
            downloadRateHistory: service.downloadRateHistory.values,
            uploadRateHistory: service.uploadRateHistory.values,
            routerJitter: service.routerHistory.jitter,
            internetJitter: service.internetHistory.jitter,
            routerLoss: service.routerHistory.lossPercentage,
            internetLoss: service.internetHistory.lossPercentage,
            isRunning: service.isRunning,
            gatewayIP: service.gatewayIP,
            captivePortalStatus: service.captivePortalStatus,
            dnsServers: service.dnsServers,
            hasLocationPermission: service.hasLocationPermission,
            defaultRouteInterface: service.defaultRouteInterface,
            defaultRoutePortName: service.defaultRoutePortName,
            currentDownloadRate: service.currentDownloadRate,
            currentUploadRate: service.currentUploadRate,
            totalDownloaded: service.totalDownloaded,
            totalUploaded: service.totalUploaded,
            dataUsage: service.dataUsageSnapshot
        )

        if newSnapshot != snapshot {
            snapshot = newSnapshot
        }
    }

    var wifiInfo: WiFiInfo? { snapshot.wifiInfo }
    var routerLatency: Double? { snapshot.routerLatency }
    var internetLatency: Double? { snapshot.internetLatency }
    var dnsLatency: Double? { snapshot.dnsLatency }
    var routerHistory: [Double?] { snapshot.routerHistory }
    var internetHistory: [Double?] { snapshot.internetHistory }
    var dnsHistory: [Double?] { snapshot.dnsHistory }
    var wifiSignalHistory: [Double?] { snapshot.wifiSignalHistory }
    var wifiNoiseHistory: [Double?] { snapshot.wifiNoiseHistory }
    var wifiRateHistory: [Double?] { snapshot.wifiRateHistory }
    var routerJitterHistory: [Double?] { snapshot.routerJitterHistory }
    var internetJitterHistory: [Double?] { snapshot.internetJitterHistory }
    var routerLossHistory: [Double?] { snapshot.routerLossHistory }
    var internetLossHistory: [Double?] { snapshot.internetLossHistory }
    var downloadRateHistory: [Double?] { snapshot.downloadRateHistory }
    var uploadRateHistory: [Double?] { snapshot.uploadRateHistory }
    var isRunning: Bool { snapshot.isRunning }
    var gatewayIP: String? { snapshot.gatewayIP }
    var captivePortalStatus: CaptivePortalStatus { snapshot.captivePortalStatus }
    var dnsServers: [String] { snapshot.dnsServers }
    var hasLocationPermission: Bool { snapshot.hasLocationPermission }
    var defaultRouteInterface: String? { snapshot.defaultRouteInterface }
    var defaultRoutePortName: String? { snapshot.defaultRoutePortName }
    var currentDownloadRate: Double? { snapshot.currentDownloadRate }
    var currentUploadRate: Double? { snapshot.currentUploadRate }
    var totalDownloaded: Double? { snapshot.totalDownloaded }
    var totalUploaded: Double? { snapshot.totalUploaded }
    var dataUsage: DataUsageSnapshot { snapshot.dataUsage }

    var routerLoss: Double {
        snapshot.routerLoss
    }

    var internetLoss: Double {
        snapshot.internetLoss
    }

    var routerJitter: Double? {
        snapshot.routerJitter
    }

    var internetJitter: Double? {
        snapshot.internetJitter
    }

    var isCaptivePortal: Bool {
        guard case .captivePortal = captivePortalStatus else { return false }
        return true
    }

    var connectionStatus: ConnectionStatus {
        if isCaptivePortal { return .limited }
        if internetLatency == nil {
            if wifiInfo == nil && defaultRouteInterface == nil { return .offline }
            return .limited
        }
        if internetLoss >= 5 { return .limited }
        return .connected
    }

    var showLegacyWifiBanner: Bool {
        guard let wifi = wifiInfo else { return false }
        return wifi.standard.isLegacy && wifi.band == .band2GHz
    }

    var activeConnectionType: ActiveConnectionType {
        if let routeInterface = defaultRouteInterface {
            if let wifiInterface = wifiInfo?.interfaceName, routeInterface == wifiInterface {
                return .wifi
            }
            let port = (defaultRoutePortName ?? "").lowercased()
            if port.contains("thunderbolt") { return .thunderbolt }
            if port.contains("ethernet") || port.contains("lan") { return .ethernet }
            return .other(defaultRoutePortName ?? routeInterface)
        }
        return wifiInfo == nil ? .other(nil) : .wifi
    }

    var primaryConnectionName: String {
        switch activeConnectionType {
        case .wifi:
            return wifiInfo?.ssid ?? "Wi-Fi"
        case .ethernet:
            return "Ethernet"
        case .thunderbolt:
            return "Thunderbolt"
        case .other(let name):
            return name ?? "Network"
        }
    }

    

    func requestLocationPermission() {
        service.requestLocationPermission()
    }

    func clearDataUsageHistory() {
        service.clearDataUsageHistory()
        refresh()
    }

    func openCaptivePortalLogin() {
        service.openCaptivePortalLogin()
    }

    func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network") {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func runSpeedTest() {
        speedTestState = .running(.preparing)
        speedTestService.run(routerHost: gatewayIP, phase: { [weak self] phase in
            self?.speedTestState = .running(phase)
        }) { [weak self] result in
            switch result {
            case .success(let result):
                self?.speedTestState = .completed(result)
            case .failure(let error):
                switch error {
                case .cancelled:
                    self?.speedTestState = .cancelled
                case .failed(let message):
                    self?.speedTestState = .failed(message)
                }
            }
        }
    }

    func cancelSpeedTest() {
        speedTestService.cancel()
        speedTestState = .cancelled
    }

    func colorForPing(_ ms: Double?) -> Color {
        guard let ms = ms else { return .secondary }
        switch ms {
        case ..<50: return .green
        case ..<150: return .orange
        default: return .red
        }
    }

    func colorForInternetProbe(_ ms: Double?) -> Color {
        guard let ms = ms else { return .secondary }
        switch ms {
        case ..<100: return .green
        case ..<300: return .orange
        default: return .red
        }
    }

    func colorForJitter(_ ms: Double?) -> Color {
        guard let ms = ms else { return .red }
        switch ms {
        case ..<5: return .green
        case ..<20: return .orange
        default: return .red
        }
    }

    func colorForSignal(_ rssi: Int) -> Color {
        switch rssi {
        case (-50)...: return .green
        case (-70)...: return .orange
        default: return .red
        }
    }

    func colorForNoise(_ noise: Int) -> Color {
        switch noise {
        case ...(-90): return .green
        case ...(-80): return .orange
        default: return .red
        }
    }

    func colorForRate(_ rate: Double, band: WiFiBand) -> Color {
        switch rateStatus(rate, band: band) {
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }

    func colorForLoss(_ loss: Double) -> Color {
        switch loss {
        case 0: return .green
        case ..<5: return .orange
        default: return .red
        }
    }

    func colorForDns(_ ms: Double?) -> Color {
        guard let ms = ms else { return .red }
        switch ms {
        case ..<50: return .green
        case ..<150: return .orange
        default: return .red
        }
    }

    private func rateStatus(_ rate: Double, band: WiFiBand) -> MetricStatus {
        let thresholds: (warn: Double, bad: Double)
        switch band {
        case .band2GHz:
            thresholds = (warn: 150, bad: 50)
        case .band5GHz, .band6GHz:
            thresholds = (warn: 400, bad: 150)
        case .unknown:
            thresholds = (warn: 200, bad: 80)
        }

        switch rate {
        case ..<thresholds.bad: return .bad
        case ..<thresholds.warn: return .warning
        default: return .good
        }
    }
}
