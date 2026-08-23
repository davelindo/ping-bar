import Foundation
import Network
import dnssd
import SystemConfiguration

final class DNSService: @unchecked Sendable {
    private let hostname: String

    init(hostname: String = "cloudflare.com") {
        self.hostname = hostname
    }

    func lookup() -> Double? {
        let start = CFAbsoluteTimeGetCurrent()
        var serviceRef: DNSServiceRef?
        let probe = DNSResolutionProbe()
        let signalBox = DNSResolutionSignal()
        let context = DNSCallbackContext(probe: probe, signal: signalBox)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        let callback: DNSServiceGetAddrInfoReply = { _, flags, _, errorCode, _, address, _, context in
            guard let context else { return }
            let hasAddress = errorCode == kDNSServiceErr_NoError
                && flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
                && address != nil
            Unmanaged<DNSCallbackContext>.fromOpaque(context)
                .takeUnretainedValue()
                .finish(success: hasAddress)
        }

        let startStatus = DNSServiceGetAddrInfo(
            &serviceRef,
            0,
            0,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
            hostname,
            callback,
            contextPointer
        )
        guard startStatus == kDNSServiceErr_NoError, let serviceRef else {
            Unmanaged<DNSCallbackContext>.fromOpaque(contextPointer).release()
            return nil
        }

        let queue = DispatchQueue(label: "com.davelindo.pingbar.dns-probe")
        guard DNSServiceSetDispatchQueue(serviceRef, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(serviceRef)
            Unmanaged<DNSCallbackContext>.fromOpaque(contextPointer).release()
            return nil
        }

        _ = signalBox.semaphore.wait(timeout: .now() + 2.0)

        let deallocationCompleted = DispatchSemaphore(value: 0)
        let cleanupTask = DNSCleanupTask(serviceRef: serviceRef, contextPointer: contextPointer)
        queue.async {
            cleanupTask.perform()
            deallocationCompleted.signal()
        }

        _ = deallocationCompleted.wait(timeout: .now() + 1.0)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return probe.isSuccess ? elapsed : nil
    }

    func currentServers() -> [String] {
        if let activeServers = Self.activeResolverServers(), !activeServers.isEmpty {
            return activeServers
        }
        guard let contents = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return []
        }
        return contents
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("nameserver") else { return nil }
                let parts = trimmed.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                return String(parts[1])
            }
    }

    static func activeResolverServers() -> [String]? {
        guard let store = SCDynamicStoreCreate(nil, "PingBar DNS Servers" as CFString, nil, nil) else {
            return nil
        }

        guard let dnsValue = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) else {
            return []
        }

        let servers: [String]
        if let dnsDictionary = dnsValue as? [String: Any],
           let addresses = dnsDictionary["ServerAddresses"] as? [String] {
            servers = addresses
        } else if let addresses = dnsValue as? [String] {
            servers = addresses
        } else {
            servers = []
        }

        return servers.filter(Self.isValidIPAddress)
    }

    private static func isValidIPAddress(_ address: String) -> Bool {
        var ipv4Address = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            return true
        }

        var ipv6Address = in6_addr()
        return address.withCString({ inet_pton(AF_INET6, $0, &ipv6Address) }) == 1
    }
}

private final class DNSCallbackContext {
    private let probe: DNSResolutionProbe
    private let signal: DNSResolutionSignal

    init(probe: DNSResolutionProbe, signal: DNSResolutionSignal) {
        self.probe = probe
        self.signal = signal
    }

    func finish(success newValue: Bool) {
        probe.finish(success: newValue, signal: signal.semaphore)
    }
}

private final class DNSResolutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var success = false

    var isSuccess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return success
    }

    func finish(success newValue: Bool) {
        lock.lock()
        success = newValue
        lock.unlock()
    }

    func finish(success newValue: Bool, signal semaphore: DispatchSemaphore) {
        lock.lock()
        let shouldSignal = newValue && !success
        success = success || newValue
        lock.unlock()

        if shouldSignal {
            semaphore.signal()
        }
    }
}

private final class DNSResolutionSignal: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
}

private final class DNSCleanupTask: @unchecked Sendable {
    private let serviceRef: DNSServiceRef?
    private let contextPointer: UnsafeMutableRawPointer

    init(serviceRef: DNSServiceRef?, contextPointer: UnsafeMutableRawPointer) {
        self.serviceRef = serviceRef
        self.contextPointer = contextPointer
    }

    func perform() {
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
        }
        Unmanaged<DNSCallbackContext>.fromOpaque(contextPointer).release()
    }
}
