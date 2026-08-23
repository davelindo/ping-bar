import XCTest
@testable import PingBar

final class PingServiceTests: XCTestCase {
    func testLatencyParserExtractsMilliseconds() {
        let output = "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms"

        XCTAssertEqual(PingService.latency(from: output), 12.345)
    }

    func testLatencyParserReturnsNilWhenNoSampleExists() {
        XCTAssertNil(PingService.latency(from: "ping: sendto: No route to host"))
    }

}
