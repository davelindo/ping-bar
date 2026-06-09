import XCTest
@testable import PingBar

final class UInt64UtilsTests: XCTestCase {
    func testSaturatingAddCapsAtMax() {
        XCTAssertEqual(UInt64.max.saturatingAdd(1), UInt64.max)
        XCTAssertEqual(UInt64(40).saturatingAdd(2), 42)
    }

    func testSaturatingSubtractFloorsAtZero() {
        XCTAssertEqual(UInt64(1).saturatingSubtract(2), 0)
        XCTAssertEqual(UInt64(42).saturatingSubtract(40), 2)
    }
}
