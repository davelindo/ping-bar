import Foundation
import Darwin

struct ThroughputSample {
    let timestamp: Date
    let inBytes: UInt64
    let outBytes: UInt64
    let counterMaximum: UInt64?
}

final class ThroughputService {
    func sample(interfaceName: String?) -> ThroughputSample? {
        guard let interfaceName, !interfaceName.isEmpty else { return nil }
        if let sample = sample64(interfaceName: interfaceName) {
            return sample
        }
        AppLog.throughput.error("Falling back to getifaddrs counters for interface \(interfaceName, privacy: .public)")

        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else {
            AppLog.throughput.error("getifaddrs failed for interface \(interfaceName, privacy: .public)")
            return nil
        }
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
                    outBytes: UInt64(networkData.ifi_obytes),
                    counterMaximum: UInt64(UInt32.max)
                )
            }
            guard let next = iface.ifa_next else { break }
            pointer = next
        }

        return nil
    }

    private func sample64(interfaceName: String) -> ThroughputSample? {
        let interfaceIndex = if_nametoindex(interfaceName)
        guard interfaceIndex > 0 else { return nil }

        var mib: [Int32] = [
            CTL_NET,
            PF_ROUTE,
            0,
            0,
            NET_RT_IFLIST2,
            Int32(interfaceIndex)
        ]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            return nil
        }

        var offset = 0
        while offset + MemoryLayout<if_msghdr2>.size <= length {
            let messageLength = buffer.withUnsafeBytes { bytes in
                bytes.baseAddress!
                    .advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr2.self)
                    .pointee
                    .ifm_msglen
            }
            guard messageLength > 0 else { break }

            if let sample = buffer.withUnsafeBytes({ bytes -> ThroughputSample? in
                let message = bytes.baseAddress!
                    .advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr2.self)
                    .pointee
                guard message.ifm_type == UInt8(RTM_IFINFO2) else { return nil }
                return ThroughputSample(
                    timestamp: Date(),
                    inBytes: UInt64(message.ifm_data.ifi_ibytes),
                    outBytes: UInt64(message.ifm_data.ifi_obytes),
                    counterMaximum: nil
                )
            }) {
                return sample
            }

            offset += Int(messageLength)
        }

        return nil
    }
}
