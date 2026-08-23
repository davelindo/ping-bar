import Foundation
import SystemConfiguration

@MainActor
final class DiagnosticsService {
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
    private let dataUsageSnapshotRefreshInterval: TimeInterval = 5.0
    private let dnsServersRefreshInterval: TimeInterval = 60.0
    private(set) var isRunning = false
    private var isDetailedSamplingEnabled = false
    private var isTickInFlight = false
    private var pendingDetailedTick = false
    private var pendingCatchUpTick = false
    private var detailedGeneration = 0
    private var monitoringRunID = UUID()
    private var isStopRequested = false
    private var lastDataUsageSnapshotRefresh = Date.distantPast
    private var lastDNSServersRefresh = Date.distantPast
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
    private let interfaceDisplayNameCache = InterfaceDisplayNameCache()
    private let routeDetector: @Sendable () -> (gateway: String?, interface: String?)

    init(routeDetector: @escaping @Sendable () -> (gateway: String?, interface: String?) = DefaultRouteProbe.systemDetector) {
        self.routeDetector = routeDetector
        locationManager.onAuthorizationChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onUpdate?()
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isStopRequested = false
        let runID = UUID()
        monitoringRunID = runID

        applyRouteInfo(routeDetector())
        if internetPingService == nil {
            internetPingService = PingService(target: internetTarget, backend: .tcpConnect(port: 443))
        }
        refreshDataUsageSnapshot(force: true)

        checkCaptivePortal()
        tick()
        scheduleTickTimer()
        captivePortalTimer = Timer.scheduledTimer(withTimeInterval: captivePortalInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkCaptivePortal()
            }
        }
        captivePortalTimer?.tolerance = 10.0
    }

    func stop() {
        guard !isStopRequested else { return }
        isStopRequested = true
        timer?.invalidate()
        timer = nil
        isTickInFlight = false
        pendingCatchUpTick = false
        pendingDetailedTick = false
        captivePortalTimer?.invalidate()
        captivePortalTimer = nil
        isRunning = false
        monitoringRunID = UUID()
        clear()
        captivePortalStatus = .unknown
        onUpdate?()
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
        guard enabled != isDetailedSamplingEnabled else { return }
        isDetailedSamplingEnabled = enabled
        if !enabled {
            detailedGeneration += 1
            pendingDetailedTick = false
        }
        if enabled {
            refreshDataUsageSnapshot(force: true)
        }
    }

    func setDataUsageHistoryEnabled(_ enabled: Bool) {
        isDataUsageHistoryEnabled = enabled
        refreshDataUsageSnapshot(force: true)
    }

    func setPerNetworkUsageEnabled(_ enabled: Bool) {
        isPerNetworkUsageEnabled = enabled
        refreshDataUsageSnapshot(force: true)
    }

    func setDataUsageRetentionDays(_ days: Int) {
        dataUsageStore.setRetentionDays(days)
        refreshDataUsageSnapshot(force: true)
    }

    func clearDataUsageHistory() {
        dataUsageStore.clear()
        refreshDataUsageSnapshot(force: true)
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
        guard isRunning, !isStopRequested else { return }
        let portalCheckRunID = monitoringRunID
        captivePortalService.check { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isRunning,
                      !self.isStopRequested,
                      self.monitoringRunID == portalCheckRunID,
                      self.captivePortalStatus != status else {
                    return
                }
                self.captivePortalStatus = status
                self.onUpdate?()
            }
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
            } else {
                pendingCatchUpTick = true
            }
            return
        }
        isTickInFlight = true
        let generation = detailedGeneration
        let tickRunID = monitoringRunID
        let detailed = isDetailedSamplingEnabled || forceDetailed
        let probeDNSService = detailed ? dnsService : nil
        let probeWiFiService = detailed ? wifiService : nil
        let wifiService = self.wifiService
        let throughputService = self.throughputService

        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }

            let routeInfo = routeDetector()
            let (routerService, internetService): (PingService?, PingService?) =
                await MainActor.run {
                    guard self.isRunning, self.monitoringRunID == tickRunID else {
                        return (nil, nil)
                    }
                    self.applyRouteInfo(routeInfo)
                    return (
                        detailed ? self.routerPingService : nil,
                        self.internetPingService
                    )
                }

            let wifiInfoBox = ProbeResultBox<WiFiIdentity?>()
            let wifiDetailBox = ProbeResultBox<WiFiInfo?>()
            let routerLatencyBox = ProbeResultBox<Double?>()
            let internetLatencyBox = ProbeResultBox<Double?>()
            let dnsLatencyBox = ProbeResultBox<Double?>()
            let throughputSampleBox = ProbeResultBox<ThroughputSample?>()
            let wifiInfoGroup = DispatchGroup()

            if detailed {
                wifiInfoGroup.enter()
                DispatchQueue.global(qos: .background).async {
                    let info = probeWiFiService?.getCurrentInfo()
                    wifiInfoBox.value = info.map { WiFiIdentity(ssid: $0.ssid, interfaceName: $0.interfaceName) }
                    wifiDetailBox.value = info
                    wifiInfoGroup.leave()
                }
            } else {
                wifiInfoGroup.enter()
                DispatchQueue.global(qos: .background).async {
                    let identity = wifiService.getCurrentIdentity()
                    wifiInfoBox.value = identity
                    wifiInfoGroup.leave()
                }
            }

            if detailed, let routerService {
                wifiInfoGroup.enter()
                DispatchQueue.global(qos: .background).async {
                    routerLatencyBox.value = routerService.executePing()
                    wifiInfoGroup.leave()
                }
            }

            if let internetService {
                wifiInfoGroup.enter()
                DispatchQueue.global(qos: .background).async {
                    internetLatencyBox.value = internetService.executePing()
                    wifiInfoGroup.leave()
                }
            }

            if probeDNSService != nil {
                wifiInfoGroup.enter()
                DispatchQueue.global(qos: .background).async {
                    dnsLatencyBox.value = probeDNSService?.lookup()
                    wifiInfoGroup.leave()
                }
            }

            wifiInfoGroup.enter()
            DispatchQueue.global(qos: .background).async {
                throughputSampleBox.value = throughputService.sample(interfaceName: routeInfo.interface)
                wifiInfoGroup.leave()
            }

            let probedValues = await withCheckedContinuation { (continuation: CheckedContinuation<ProbeValues, Never>) in
                wifiInfoGroup.notify(queue: .global(qos: .background)) {
                    continuation.resume(returning: ProbeValues(
                        wifiIdentity: wifiInfoBox.value ?? nil,
                        wifiInfo: wifiDetailBox.value.flatMap { $0 },
                        routerLatency: routerLatencyBox.value.flatMap { $0 },
                        internetLatency: internetLatencyBox.value.flatMap { $0 },
                        dnsLatency: dnsLatencyBox.value.flatMap { $0 },
                        throughputSample: throughputSampleBox.value.flatMap { $0 }
                    ))
                }
            }

            let probedWiFiIdentity = probedValues.wifiIdentity
            let probedWiFiInfo = probedValues.wifiInfo
            let probedRouterLatency = probedValues.routerLatency
            let probedInternetLatency = probedValues.internetLatency
            let probedDNSLatency = probedValues.dnsLatency
            let probedThroughputSample = probedValues.throughputSample

            await MainActor.run {
                guard self.isRunning, self.monitoringRunID == tickRunID else {
                    // A stale task must never repopulate route state cleared by stop().
                    return
                }

                self.applyRouteInfo(routeInfo)

                self.internetHistory.add(probedInternetLatency)
                if detailed {
                    self.wifiInfo = probedWiFiInfo
                    self.wifiSignalHistory.add(probedWiFiInfo.map { Double($0.rssi) })
                    self.wifiNoiseHistory.add(probedWiFiInfo.map { Double($0.noise) })
                    self.wifiRateHistory.add(probedWiFiInfo.map { $0.linkRate })
                    self.routerHistory.add(probedRouterLatency)
                    self.dnsHistory.add(probedDNSLatency)
                    self.routerJitterHistory.add(self.routerHistory.jitter)
                    self.internetJitterHistory.add(self.internetHistory.jitter)
                    self.routerLossHistory.add(probedRouterLatency == nil ? 100 : 0)
                    self.internetLossHistory.add(probedInternetLatency == nil ? 100 : 0)
                } else {
                    self.recordDetailedSamplingGap()
                }
                self.applyWiFiIdentity(probedWiFiIdentity)
                self.updateThroughput(sample: probedThroughputSample)
                if detailed {
                    self.refreshDataUsageSnapshot()
                }
                let isStaleDetailedCycle = detailed && generation != self.detailedGeneration

                let runPendingDetailedTick = self.pendingDetailedTick
                self.pendingDetailedTick = false
                let runPendingCatchUpTick = self.pendingCatchUpTick
                self.pendingCatchUpTick = false

                let shouldNotify = !isStaleDetailedCycle || runPendingDetailedTick || runPendingCatchUpTick
                let followUpIsDetailed = isStaleDetailedCycle ? false : runPendingDetailedTick

                if shouldNotify {
                    self.onUpdate?()
                }

                let hasFollowUp = isStaleDetailedCycle || runPendingDetailedTick || runPendingCatchUpTick
                // Release the current cycle before re-entering tick(); otherwise a
                // follow-up is only queued and the scheduler remains busy forever.
                self.isTickInFlight = false

                if hasFollowUp {
                    self.tick(forceDetailed: followUpIsDetailed)
                }
            }
        }
    }

    private func applyRouteInfo(_ routeInfo: (gateway: String?, interface: String?)) {
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
            let displayName = interfaceDisplayNameCache.displayName(for: interface)
                ?? loadInterfacePortMap()[interface]
                ?? interface
            defaultRoutePortName = displayName == kSCNetworkInterfaceTypeEthernet as String
                ? "Ethernet"
                : displayName
        } else {
            defaultRoutePortName = nil
        }

        let now = Date()
        let shouldRefreshDNS = routeChanged
            || dnsServers.isEmpty
            || now.timeIntervalSince(lastDNSServersRefresh) >= dnsServersRefreshInterval

        if shouldRefreshDNS {
            lastDNSServersRefresh = now
            refreshDNSServers()
        }

        if routeChanged {
            resetThroughput()
        }
    }

    func clear() {
        wifiInfo = nil
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
        gatewayIP = nil
        defaultRoutePortName = nil
        dnsServers = []
        resetThroughput()
    }

    private func scheduleTickTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
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

    private func recordDetailedSamplingGap() {
        wifiSignalHistory.add(nil)
        wifiNoiseHistory.add(nil)
        wifiRateHistory.add(nil)
        routerHistory.add(nil)
        dnsHistory.add(nil)
        routerJitterHistory.add(nil)
        internetJitterHistory.add(nil)
        routerLossHistory.add(nil)
        internetLossHistory.add(nil)
    }

    private func applyWiFiIdentity(_ identity: WiFiIdentity?) {
        let nextName = identity?.ssid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = nextName?.isEmpty == false ? nextName : nil
        let nextInterface = identity?.interfaceName
        if normalizedName != currentNetworkName || nextInterface != currentWiFiInterfaceName {
            currentNetworkName = normalizedName
            currentWiFiInterfaceName = nextInterface
            lastDataUsageSnapshotRefresh = .distantPast
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

    private func refreshDataUsageSnapshot(force: Bool = false, now: Date = Date()) {
        guard force || now.timeIntervalSince(lastDataUsageSnapshotRefresh) >= dataUsageSnapshotRefreshInterval else {
            return
        }
        dataUsageSnapshot = dataUsageStore.snapshot(currentNetworkName: currentNetworkName, now: now)
        lastDataUsageSnapshotRefresh = now
    }

    func flushDataUsage() {
        dataUsageStore.flush()
    }

    private func refreshDNSServers() {
        let servers = dnsService.currentServers()
        if servers != dnsServers {
            dnsServers = servers
        }
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

        guard let last = lastThroughputSample else {
            return
        }

        let deltaTime = sample.timestamp.timeIntervalSince(last.timestamp)
        guard deltaTime > 0 else {
            // Duplicate or out-of-order timestamp; skip to preserve history cadence.
            return
        }

        let deltaIn = throughputDelta(current: sample.inBytes, previous: last.inBytes, counterMaximum: last.counterMaximum)
        let deltaOut = throughputDelta(current: sample.outBytes, previous: last.outBytes, counterMaximum: last.counterMaximum)
        guard let deltaIn, let deltaOut else {
            if sample.inBytes < last.inBytes || sample.outBytes < last.outBytes {
                AppLog.throughput.error("Interface counter reset detected on \(self.defaultRouteInterface ?? "unknown", privacy: .public); resetting throughput baseline")
            } else {
                AppLog.throughput.error("Unknown counter wrap on \(self.defaultRouteInterface ?? "unknown", privacy: .public) without known maximum; resetting throughput baseline")
            }
            resetThroughput()
            downloadRateHistory.add(nil)
            uploadRateHistory.add(nil)
            throughputBaseline = sample
            lastThroughputSample = sample
            return
        }

        currentDownloadRate = Double(deltaIn) / deltaTime
        currentUploadRate = Double(deltaOut) / deltaTime
        totalDownloaded = (totalDownloaded ?? 0) + Double(deltaIn)
        totalUploaded = (totalUploaded ?? 0) + Double(deltaOut)
                if isDataUsageHistoryEnabled, deltaIn > 0 || deltaOut > 0 {
                    dataUsageStore.record(
                        downloaded: deltaIn,
                        uploaded: deltaOut,
                networkName: networkNameForAccounting(),
                now: sample.timestamp
            )
        }

        lastThroughputSample = sample
        downloadRateHistory.add(currentDownloadRate)
        uploadRateHistory.add(currentUploadRate)
    }

    private func throughputDelta(current: UInt64, previous: UInt64, counterMaximum: UInt64?) -> UInt64? {
        let delta = ThroughputCounter.delta(current: current, previous: previous, counterMaximum: counterMaximum)
        if delta != nil, current < previous {
            AppLog.throughput.error("Counter wrap detected on \(self.defaultRouteInterface ?? "unknown", privacy: .public); applying wrap correction")
        }
        return delta
    }

    private func loadInterfacePortMap() -> [String: String] {
        var map: [String: String] = [:]
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in interfaces {
            if let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
               let type = SCNetworkInterfaceGetInterfaceType(interface) as String? {
                map[bsdName] = type
            }
        }
        return map
    }
}

private final class InterfaceDisplayNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var namesByBSDName: [String: String]?

    func displayName(for bsdName: String) -> String? {
        lock.lock()
        if let cachedNames = namesByBSDName {
            let cachedName = cachedNames[bsdName]
            lock.unlock()
            return cachedName
        }
        lock.unlock()

        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var loadedNames: [String: String] = [:]
        for interface in interfaces {
            if let name = SCNetworkInterfaceGetBSDName(interface) as String? {
                loadedNames[name] = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                    ?? SCNetworkInterfaceGetInterfaceType(interface) as String?
            }
        }

        lock.lock()
        namesByBSDName = loadedNames
        let displayName = loadedNames[bsdName]
        lock.unlock()
        return displayName
    }
}

enum DefaultRouteProbe {
    static func detect(_ detector: () -> (gateway: String?, interface: String?) = DefaultRouteProbe.systemDetector) -> (gateway: String?, interface: String?) {
        detector()
    }

    static let systemDetector: @Sendable () -> (gateway: String?, interface: String?) = {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, AF_INET, 0, NET_RT_DUMP, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return (nil, nil)
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            return (nil, nil)
        }

        var offset = 0
        while offset + MemoryLayout<rt_msghdr>.size <= length {
            let message = buffer.withUnsafeBytes { bytes in
                bytes.baseAddress!
                    .advanced(by: offset)
                    .assumingMemoryBound(to: rt_msghdr.self)
                    .pointee
            }
            let messageLength = Int(message.rtm_msglen)
            guard messageLength >= MemoryLayout<rt_msghdr>.size, offset + messageLength <= length else {
                break
            }

            let isDefaultRoute = message.rtm_type == UInt8(RTM_GET)
                && message.rtm_flags & RTF_UP != 0
                && message.rtm_flags & RTF_GATEWAY != 0
                && message.rtm_flags & RTF_STATIC != 0
            if isDefaultRoute, let route = routeAddresses(from: buffer, message: message, offset: offset) {
                return route
            }

            offset += messageLength
        }

        return (nil, nil)
    }

    private static func routeAddresses(
        from buffer: [UInt8],
        message: rt_msghdr,
        offset: Int
    ) -> (gateway: String, interface: String)? {
        var cursor = offset + MemoryLayout<rt_msghdr>.size
        var destination: String?
        var gateway: String?
        var netmask: String?

        for bit in 0..<8 where message.rtm_addrs & (1 << Int32(bit)) != 0 {
            guard cursor + 2 <= offset + Int(message.rtm_msglen) else { break }
            let addressLength = Int(buffer[cursor])
            let addressFamily = Int(buffer[cursor + 1])
            guard addressLength > 0 else { break }
            guard cursor + addressLength <= offset + Int(message.rtm_msglen) else { break }

            if addressFamily == AF_INET, addressLength >= MemoryLayout<sockaddr_in>.size {
                let address = buffer.withUnsafeBytes { bytes in
                    bytes.loadUnaligned(fromByteOffset: cursor + MemoryLayout<in_addr_t>.size, as: in_addr.self)
                }
                let text = ipAddress(address)
                switch bit {
                case 0: destination = text
                case 1: gateway = text
                case 2: netmask = text
                default: break
                }
            }

            cursor += (addressLength + 3) & ~3
        }

        guard destination == "0.0.0.0",
              netmask == nil || netmask == "0.0.0.0",
              let gateway else {
            return nil
        }

        guard let interface = interfaceName(for: Int32(message.rtm_index)) else {
            return nil
        }
        return (gateway, interface)
    }

    private static func ipAddress(_ address: in_addr) -> String {
        let octets = withUnsafeBytes(of: address.s_addr) { Array($0) }
        return octets.map(String.init).joined(separator: ".")
    }

    private static func interfaceName(for index: Int32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard index > 0, if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(decoding: name.map(UInt8.init).prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

private final class ProbeResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var underlyingValue: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return underlyingValue
        }
        set {
            lock.lock()
            underlyingValue = newValue
            lock.unlock()
        }
    }
}

private struct ProbeValues: Sendable {
    var wifiIdentity: WiFiIdentity?
    var wifiInfo: WiFiInfo?
    var routerLatency: Double?
    var internetLatency: Double?
    var dnsLatency: Double?
    var throughputSample: ThroughputSample?
}
