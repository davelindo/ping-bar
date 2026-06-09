import Foundation

enum ThroughputCounter {
    static func delta(current: UInt64, previous: UInt64, counterMaximum: UInt64?) -> UInt64? {
        if current >= previous {
            return current - previous
        }
        guard let counterMaximum else {
            return nil
        }
        return counterMaximum.saturatingSubtract(previous).saturatingAdd(current).saturatingAdd(1)
    }
}
