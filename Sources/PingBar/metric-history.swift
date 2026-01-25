import Foundation

final class MetricHistory {
    private var buffer: [Double?]
    private var index = 0
    private var isFull = false
    let capacity: Int
    private var cachedValues: [Double?] = []
    private var cachedNonNilValues: [Double] = []
    private var cachedLatest: Double?
    private var cachedAverage: Double?
    private var cachedJitter: Double?
    private var cachedLossPercentage: Double = 0
    private var cachedMin: Double?
    private var cachedMax: Double?

    init(capacity: Int = 60) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
        recalculate()
    }

    func add(_ value: Double?) {
        buffer[index] = value
        index = (index + 1) % capacity
        if index == 0 { isFull = true }
        recalculate()
    }

    var values: [Double?] {
        cachedValues
    }

    var nonNilValues: [Double] {
        cachedNonNilValues
    }

    var latest: Double? {
        cachedLatest
    }

    var average: Double? {
        cachedAverage
    }

    var jitter: Double? {
        cachedJitter
    }

    var lossPercentage: Double {
        cachedLossPercentage
    }

    var minValue: Double? {
        cachedMin
    }

    var maxValue: Double? {
        cachedMax
    }

    func clear() {
        buffer = Array(repeating: nil, count: capacity)
        index = 0
        isFull = false
        recalculate()
    }

    private func recalculate() {
        if isFull {
            cachedValues = Array(buffer[index...]) + Array(buffer[..<index])
        } else {
            cachedValues = Array(buffer[..<index])
        }

        cachedLatest = cachedValues.last.flatMap { $0 }
        cachedNonNilValues.removeAll(keepingCapacity: true)
        cachedNonNilValues.reserveCapacity(cachedValues.count)

        var nilCount = 0
        var minVal = Double.greatestFiniteMagnitude
        var maxVal = -Double.greatestFiniteMagnitude

        for value in cachedValues {
            guard let value else {
                nilCount += 1
                continue
            }
            cachedNonNilValues.append(value)
            minVal = min(minVal, value)
            maxVal = max(maxVal, value)
        }

        let total = cachedValues.count
        cachedLossPercentage = total > 0 ? Double(nilCount) / Double(total) * 100 : 0

        guard !cachedNonNilValues.isEmpty else {
            cachedAverage = nil
            cachedJitter = nil
            cachedMin = nil
            cachedMax = nil
            return
        }

        cachedMin = minVal
        cachedMax = maxVal

        let sum = cachedNonNilValues.reduce(0, +)
        let avg = sum / Double(cachedNonNilValues.count)
        cachedAverage = avg

        guard cachedNonNilValues.count > 1 else {
            cachedJitter = nil
            return
        }

        var deviationSum = 0.0
        for value in cachedNonNilValues {
            deviationSum += abs(value - avg)
        }
        cachedJitter = deviationSum / Double(cachedNonNilValues.count)
    }
}
