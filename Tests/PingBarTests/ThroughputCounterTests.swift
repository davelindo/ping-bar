import XCTest
@testable import PingBar

final class ThroughputCounterTests: XCTestCase {
    func testDeltaWithoutWrap() {
        XCTAssertEqual(ThroughputCounter.delta(current: 150, previous: 100, counterMaximum: nil), 50)
    }

    func testDeltaCorrectsKnownCounterWrap() {
        XCTAssertEqual(
            ThroughputCounter.delta(current: 10, previous: UInt64(UInt32.max) - 4, counterMaximum: UInt64(UInt32.max)),
            15
        )
    }

    func testDeltaReturnsNilForResetWithUnknownCounterMaximum() {
        XCTAssertNil(ThroughputCounter.delta(current: 10, previous: 100, counterMaximum: nil))
    }
}
