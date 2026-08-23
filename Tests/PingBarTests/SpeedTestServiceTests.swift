import XCTest

@testable import PingBar

final class SpeedTestServiceTests: XCTestCase {
    @MainActor
    func testImmediateCancellationReleasesRunAndDeliversCancelled() async throws {
        let service = SpeedTestService(latencyOperation: { _, _ in
            Thread.sleep(forTimeInterval: 0.1)
            return nil
        })

        let completion = expectation(description: "cancelled completion")
        var outcome: Result<SpeedTestResult, SpeedTestError>?
        service.run(
            routerHost: nil,
            phase: { _ in },
            completion: { result in
                outcome = result
                completion.fulfill()
            }
        )

        service.cancel()
        await fulfillment(of: [completion], timeout: 2)

        guard case .failure(.cancelled) = outcome else {
            return XCTFail("Expected cancellation")
        }

        let nextPreparing = expectation(description: "next run started preparing")
        service.run(
            routerHost: nil,
            phase: { phase in
                if phase == .preparing {
                    nextPreparing.fulfill()
                }
            },
            completion: { _ in }
        )

        await fulfillment(of: [nextPreparing], timeout: 0.5)
        service.cancel()
        await Task.yield()
    }
}
