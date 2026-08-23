import XCTest

@testable import PingBar

final class MetricHistoryTests: XCTestCase {
    func testMetricsMatchBruteForceAcrossWrapAndGaps() {
        let capacity = 8
        let history = MetricHistory(capacity: capacity)
        var inputs: [Double?] = [2, nil, 7, 4, 12, 1, nil, 9, 3, 5, nil, 11]
        inputs.append(contentsOf: Array(repeating: nil, count: 5))
        inputs.append(contentsOf: [6, 8])

        for input in inputs {
            history.add(input)

            let values = history.values
            XCTAssertTrue(values.count <= capacity)
            XCTAssertEqual(history.latest, values.last.flatMap { $0 })
            XCTAssertEqual(history.lossPercentage, percentageOfNil(in: values), accuracy: 1e-12)

            let expected = nonNilStatistics(in: values)
            if let actualAverage = history.average, let expectedMean = expected.mean {
                XCTAssertEqual(actualAverage, expectedMean, accuracy: 1e-10)
            } else {
                XCTAssertNil(history.average)
                XCTAssertNil(expected.mean)
            }

            if let actualJitter = history.jitter, let expectedJitter = expected.standardDeviation {
                XCTAssertEqual(actualJitter, expectedJitter, accuracy: 1e-9)
            } else {
                XCTAssertNil(history.jitter)
                XCTAssertNil(expected.standardDeviation)
            }
            XCTAssertEqual(history.minValue, expected.min)
            XCTAssertEqual(history.maxValue, expected.max)
        }
    }

    func testClearResetsAllMetrics() {
        let history = MetricHistory(capacity: 4)
        for value in [3.0, nil, 8.0] {
            history.add(value)
        }

        history.clear()

        XCTAssertNil(history.latest)
        XCTAssertNil(history.average)
        XCTAssertNil(history.jitter)
        XCTAssertNil(history.minValue)
        XCTAssertNil(history.maxValue)
        XCTAssertEqual(history.lossPercentage, 0)
        XCTAssertTrue(history.values.isEmpty)
    }

    func testRevisionIncrementsOnMutationAndClear() {
        let history = MetricHistory(capacity: 4)
        let initialRevision = history.revision

        history.add(3.0)
        XCTAssertEqual(history.revision, initialRevision + 1)

        history.add(nil)
        XCTAssertEqual(history.revision, initialRevision + 2)

        history.clear()
        XCTAssertEqual(history.revision, initialRevision + 3)
    }

    private func percentageOfNil(in values: [Double?]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter { $0 == nil }.count) / Double(values.count) * 100
    }

    private func nonNilStatistics(
        in values: [Double?]
    ) -> (mean: Double?, standardDeviation: Double?, min: Double?, max: Double?) {
        let values = values.compactMap { $0 }
        guard !values.isEmpty else { return (nil, nil, nil, nil) }

        let mean = values.reduce(0, +) / Double(values.count)
        let standardDeviation = values.count > 1
            ? (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
            : nil
        return (mean, standardDeviation, values.min(), values.max())
    }
}
