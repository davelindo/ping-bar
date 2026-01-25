import Foundation
import SystemConfiguration

struct ThroughputSample {
    let timestamp: Date
    let inBytes: UInt64
    let outBytes: UInt64
}

final class ThroughputService {
    func sample(interfaceName: String?) -> ThroughputSample? {
        guard let interfaceName, !interfaceName.isEmpty else { return nil }

        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var pointer = first
        while true {
            let iface = pointer.pointee
            let name = String(cString: iface.ifa_name)
            if name == interfaceName, let data = iface.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                return ThroughputSample(
                    timestamp: Date(),
                    inBytes: UInt64(networkData.ifi_ibytes),
                    outBytes: UInt64(networkData.ifi_obytes)
                )
            }
            guard let next = iface.ifa_next else { break }
            pointer = next
        }

        return nil
    }
}
