import Foundation

extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 {
        let result = addingReportingOverflow(value)
        return result.overflow ? UInt64.max : result.partialValue
    }

    func saturatingSubtract(_ value: UInt64) -> UInt64 {
        value > self ? 0 : self - value
    }
}
