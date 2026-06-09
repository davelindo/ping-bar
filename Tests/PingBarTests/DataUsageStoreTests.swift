import XCTest
@testable import PingBar

final class DataUsageStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PingBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRecordFlushAndRoundTrip() {
        let fileURL = temporaryDirectory.appendingPathComponent("data-usage.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let store = DataUsageStore(fileURL: fileURL)
        store.record(downloaded: 1_024, uploaded: 512, networkName: "Office", now: now)
        store.flush()

        let reloaded = DataUsageStore(fileURL: fileURL)
        let snapshot = reloaded.snapshot(currentNetworkName: "Office", now: now)

        XCTAssertEqual(snapshot.overall.downloaded, 1_024)
        XCTAssertEqual(snapshot.overall.uploaded, 512)
        XCTAssertEqual(snapshot.currentNetworkTotals?.downloaded, 1_024)
        XCTAssertEqual(snapshot.currentNetworkTotals?.uploaded, 512)
        XCTAssertEqual(snapshot.networks.map(\.name), ["Office"])
    }

    func testCorruptFileIsQuarantinedInsteadOfOverwritten() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("data-usage.json")
        try "not json".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = DataUsageStore(fileURL: fileURL)
        let snapshot = store.snapshot(currentNetworkName: nil)

        XCTAssertEqual(snapshot.overall.total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("data-usage.corrupt-") && $0.hasSuffix(".json") })
    }

    func testRetentionPrunesDailyAndNetworkDailyRecords() {
        let fileURL = temporaryDirectory.appendingPathComponent("data-usage.json")
        let store = DataUsageStore(fileURL: fileURL)
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 12))!
        let old = calendar.date(byAdding: .day, value: -10, to: now)!

        store.record(downloaded: 100, uploaded: 0, networkName: "Office", now: old)
        store.record(downloaded: 200, uploaded: 0, networkName: "Office", now: now)
        store.setRetentionDays(7)

        let snapshot = store.snapshot(currentNetworkName: "Office", now: now)

        XCTAssertEqual(snapshot.overallDailyRecords.map(\.day), [store.dayKey(for: now)])
        XCTAssertEqual(snapshot.networkDailyRecords.map(\.day), [store.dayKey(for: now)])
        XCTAssertEqual(snapshot.currentNetworkTotals?.downloaded, 200)
    }

    func testDayKeyFormat() {
        let store = DataUsageStore(fileURL: temporaryDirectory.appendingPathComponent("data-usage.json"))
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12))!

        XCTAssertEqual(store.dayKey(for: date), "2026-01-05")
    }
}
