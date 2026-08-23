import XCTest
@testable import PingBar

final class DefaultRouteProbeTests: XCTestCase {
    @MainActor
    func testStoppedRunDoesNotRestoreRouteState() async {
        let service = DiagnosticsService(routeDetector: {
            (gateway: "192.168.100.1", interface: "en9")
        })

        service.start()
        service.stop()

        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.gatewayIP)
        XCTAssertNil(service.defaultRouteInterface)
    }
}
