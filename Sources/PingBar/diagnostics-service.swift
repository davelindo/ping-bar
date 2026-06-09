import Foundation

final class DiagnosticsService: @unchecked Sendable {
    let wifiService = WiFiService()
    private(set) var dnsService = DNSService()
    let captivePortalService = CaptivePortalService()
    let locationManager = LocationManager()
    private let throughputService = ThroughputService()
    private let dataUsageStore = DataUsageStore()

    private var routerPingService: PingService?
    private var internetPingService: PingService?
    private var internetTarget = SettingsStore.defaultInternetPingTarget
    private var dnsHostname = SettingsStore.defaultDnsLookupHost

    private(set) var wifiInfo: WiFiInfo?
    let routerHistory = MetricHistory()
    let internetHistory = MetricHistory()
    let dnsHistory = MetricHistory()
    let wifiSignalHistory = MetricHistory()
    let wifiNoiseHistory = MetricHistory()
    let wifiRateHistory = MetricHistory()
    let routerJitterHistory = MetricHistory()
    let internetJitterHistory = MetricHistory()
    let routerLossHistory = MetricHistory()
    let internetLossHistory = MetricHistory()
    let downloadRateHistory = MetricHistory()
    let uploadRateHistory = MetricHistory()

    private var timer: Timer?
    private var captivePortalTimer: Timer?
    private var tickInterval: TimeInterval = 10.0
    private let captivePortalInterval: TimeInterval = 60.0
    private(set) var isRunning = false
    private var isDetailedSamplingEnabled = false
    private var isTickInFlight = false
    private var pendingDetailedTick = false
    private var isDataUsageHistoryEnabled = true
    private var isPerNetworkUsageEnabled = true
    private(set) var gatewayIP: String?
    private(set) var defaultRouteInterface: String?
    private(set) var defaultRoutePortName: String?
    private(set) var currentNetworkName: String?
    private(set) var currentWiFiInterfaceName: String?
    private(set) var captivePortalStatus: CaptivePortalStatus = .unknown
    private(set) var dnsServers: [String] = []
    private(set) var currentDownloadRate: Double?
    private(set) var currentUploadRate: Double?
    private(set) var totalDownloaded: Double?
    private(set) var totalUploaded: Double?
    private(set) var dataUsageSnapshot = DataUsageSnapshot()

    private var throughputBaseline: ThroughputSample?
    private var lastThroughputSample: ThroughputSample?

    var onUpdate: (() -> Void)?
    private lazy var interfacePortMap: [String: String] = loadInterfacePortMap()

    init() {
        locationManager.onAuthorizationChanged = { [weak self] _ in
            self?.onUpdate?()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        updateRouteInfo()
        internetPingService = PingService(target: internetTarget, backend: .tcpConnect(port: 443))
        refreshDataUsageSnapshot()

        checkCaptivePortal()
        tick()
        scheduleTickTimer()
        captivePortalTimer = Timer.scheduledTimer(withTimeInterval: captivePortalInterval, repeats: true) { [weak self] _ in
            self?.updateRouteInfo()
            self?.checkCaptivePortal()
        }
        captivePortalTimer?.tolerance = 10.0
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captivePortalTimer?.invalidate()
        captivePortalTimer = nil
        isRunning = false
        flushDataUsage()
        clear()
        captivePortalStatus = .unknown
        onUpdate?()
    }

    func shutdown() {
        flushDataUsage()
    }

    func setSamplingInterval(_ interval: TimeInterval, tickImmediately: Bool = false) {
        guard interval > 0 else { return }
        let shouldReschedule = interval != tickInterval
        tickInterval = interval
        if isRunning && shouldReschedule {
            scheduleTickTimer()
        }
        if tickImmediately {
            tick(forceDetailed: isDetailedSamplingEnabled)
        }
    }

    func setDetailedSamplingEnabled(_ enabled: Bool) {
        isDetailedSamplingEnabled = enabled
        if enabled {
            refreshDataUsageSnapshot()
        }
    }

    func setDataUsageHistoryEnabled(_ enabled: Bool) {
        isDataUsageHistoryEnabled = enabled
        refreshDataUsageSnapshot()
    }

    func setPerNetworkUsageEnabled(_ enabled: Bool) {
        isPerNetworkUsageEnabled = enabled
        refreshDataUsageSnapshot()
    }

    func setDataUsageRetentionDays(_ days: Int) {
        dataUsageStore.setRetentionDays(days)
        refreshDataUsageSnapshot()
    }

    func clearDataUsageHistory() {
        dataUsageStore.clear()
        refreshDataUsageSnapshot()
    }

    func updateInternetTarget(_ target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != internetTarget else { return }
        internetTarget = trimmed
        internetPingService = PingService(target: trimmed, backend: .tcpConnect(port: 443))
    }

    func updateDnsHostname(_ hostname: String) {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != dnsHostname else { return }
        dnsHostname = trimmed
        dnsService = DNSService(hostname: trimmed)
    }

    private func checkCaptivePortal() {
        captivePortalService.check { [weak self] status in
            self?.captivePortalStatus = status
            self?.onUpdate?()
        }
    }

    @MainActor
    func openCaptivePortalLogin() {
        if case .captivePortal(let url) = captivePortalStatus {
            captivePortalService.openLoginPage(url: url)
        }
    }

    func requestLocationPermission() {
        locationManager.requestPermission()
    }

    var hasLocationPermission: Bool {
        locationManager.isAuthorized
    }

    private func tick(forceDetailed: Bool = false) {
        guard !isTickInFlight else {
            if forceDetailed {
                pendingDetailedTick = true
            }
            return
        }
        isTickInFlight = true
        let detailed = isDetailedSamplingEnabled || forceDetailed
        let routeInterface = defaultRouteInterface

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            let wifiInfo = detailed ? self.wifiService.getCurrentInfo() : nil
            let wifiIdentity = wifiInfo.map { WiFiIdentity(ssid: $0.ssid, interfaceName: $0.interfaceName) }
                ?? self.wifiService.getCurrentIdentity()
            let routerLatency = detailed ? self.routerPingService?.executePing() : nil
            let internetLatency = self.internetPingService?.executePing()
            let dnsLatency = detailed ? self.dnsService.lookup() : nil
            let throughputSample = self.throughputService.sample(interfaceName: routeInterface)

            DispatchQueue.main.async {
                self.internetHistory.add(internetLatency)
                if detailed {
                    self.wifiInfo = wifiInfo
                    self.wifiSignalHistory.add(wifiInfo.map { Double($0.rssi) })
                    self.wifiNoiseHistory.add(wifiInfo.map { Double($0.noise) })
                    self.wifiRateHistory.add(wifiInfo.map { $0.linkRate })
                    self.routerHistory.add(routerLatency)
                    self.dnsHistory.add(dnsLatency)
                    self.routerJitterHistory.add(self.routerHistory.jitter)
                    self.internetJitterHistory.add(self.internetHistory.jitter)
                    self.routerLossHistory.add(routerLatency == nil ? 100 : 0)
                    self.internetLossHistory.add(internetLatency == nil ? 100 : 0)
                }
                self.applyWiFiIdentity(wifiIdentity)
                self.updateThroughput(sample: throughputSample)
                if detailed {
                    self.refreshDataUsageSnapshot()
                }
                self.isTickInFlight = false
                let runPendingDetailedTick = self.pendingDetailedTick
                self.pendingDetailedTick = false
                if runPendingDetailedTick {
                    self.tick(forceDetailed: true)
                } else {
                    self.onUpdate?()
                }
            }
        }
    }

    private func detectDefaultRoute() -> (gateway: String?, interface: String?) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, nil)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var gateway: String?
        var interface: String?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("interface:") {
                interface = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return (gateway, interface)
    }

    private func updateRouteInfo() {
        let routeInfo = detectDefaultRoute()
        let routeChanged = routeInfo.gateway != gatewayIP || routeInfo.interface != defaultRouteInterface
        if routeInfo.gateway != gatewayIP {
            gatewayIP = routeInfo.gateway
            if let gateway = gatewayIP {
                routerPingService = PingService(target: gateway, backend: .systemPing)
            } else {
                routerPingService = nil
            }
        }
        defaultRouteInterface = routeInfo.interface
        if let interface = defaultRouteInterface {
            defaultRoutePortName = interfacePortMap[interface]
        } else {
            defaultRoutePortName = nil
        }
        if routeChanged || dnsServers.isEmpty {
            dnsServers = dnsService.currentServers()
            resetThroughput()
        }
    }

    func clear() {
        wifiInfo = nil
        currentNetworkName = nil
        currentWiFiInterfaceName = nil
        routerHistory.clear()
        internetHistory.clear()
        dnsHistory.clear()
        wifiSignalHistory.clear()
        wifiNoiseHistory.clear()
        wifiRateHistory.clear()
        routerJitterHistory.clear()
        internetJitterHistory.clear()
        routerLossHistory.clear()
        internetLossHistory.clear()
        defaultRouteInterface = nil
        defaultRoutePortName = nil
        dnsServers = []
        resetThroughput()
    }

    private func scheduleTickTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = max(0.2, tickInterval * 0.15)
    }

    private func resetThroughput() {
        throughputBaseline = nil
        lastThroughputSample = nil
        currentDownloadRate = nil
        currentUploadRate = nil
        totalDownloaded = nil
        totalUploaded = nil
        downloadRateHistory.clear()
        uploadRateHistory.clear()
    }

    private func applyWiFiIdentity(_ identity: WiFiIdentity?) {
        let nextName = identity?.ssid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = nextName?.isEmpty == false ? nextName : nil
        let nextInterface = identity?.interfaceName
        if normalizedName != currentNetworkName || nextInterface != currentWiFiInterfaceName {
            currentNetworkName = normalizedName
            currentWiFiInterfaceName = nextInterface
            resetThroughput()
        }
    }

    private func networkNameForAccounting() -> String? {
        guard isPerNetworkUsageEnabled,
              let routeInterface = defaultRouteInterface,
              routeInterface == currentWiFiInterfaceName else {
            return nil
        }
        return currentNetworkName
    }

    private func refreshDataUsageSnapshot() {
        dataUsageSnapshot = dataUsageStore.snapshot(currentNetworkName: currentNetworkName)
    }

    private func flushDataUsage() {
        dataUsageStore.flush()
    }

    private func updateThroughput(sample: ThroughputSample?) {
        guard let sample else {
            currentDownloadRate = nil
            currentUploadRate = nil
            totalDownloaded = nil
            totalUploaded = nil
            downloadRateHistory.add(nil)
            uploadRateHistory.add(nil)
            return
        }

        if throughputBaseline == nil {
            throughputBaseline = sample
            lastThroughputSample = sample
            currentDownloadRate = nil
            currentUploadRate = nil
            totalDownloaded = 0
            totalUploaded = 0
            return
        }

        if let last = lastThroughputSample {
            let deltaTime = sample.timestamp.timeIntervalSince(last.timestamp)
            if deltaTime > 0 {
                let deltaIn = Int64(sample.inBytes) - Int64(last.inBytes)
                let deltaOut = Int64(sample.outBytes) - Int64(last.outBytes)
                if deltaIn >= 0, deltaOut >= 0 {
                    currentDownloadRate = Double(deltaIn) / deltaTime
                    currentUploadRate = Double(deltaOut) / deltaTime
                    if isDataUsageHistoryEnabled {
                        dataUsageStore.record(
                            downloaded: UInt64(deltaIn),
                            uploaded: UInt64(deltaOut),
                            networkName: networkNameForAccounting(),
                            now: sample.timestamp
                        )
                    }
                } else {
                    resetThroughput()
                }
            }
        }

        if let baseline = throughputBaseline {
            let totalIn = Int64(sample.inBytes) - Int64(baseline.inBytes)
            let totalOut = Int64(sample.outBytes) - Int64(baseline.outBytes)
            totalDownloaded = totalIn >= 0 ? Double(totalIn) : nil
            totalUploaded = totalOut >= 0 ? Double(totalOut) : nil
        }

        lastThroughputSample = sample
        downloadRateHistory.add(currentDownloadRate)
        uploadRateHistory.add(currentUploadRate)
    }

    private func loadInterfacePortMap() -> [String: String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var map: [String: String] = [:]
        var currentPort: String?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                currentPort = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:") {
                let device = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if let port = currentPort, !device.isEmpty {
                    map[device] = port
                }
            }
        }

        return map
    }
}
