import Foundation

final class MetricHistory {
    private var buffer: [Double?]
    private var index = 0
    private var isFull = false
    let capacity: Int
    private var cachedLatest: Double?
    private var cachedAverage: Double?
    private var cachedJitter: Double?
    private var cachedLossPercentage: Double = 0
    private var cachedMin: Double?
    private var cachedMax: Double?
    private var sum = 0.0
    private var sumOfSquares = 0.0
    private var nonNilCount = 0
    private var valueCounts: [Double: Int] = [:]
    private var cachedValues: [Double?]?
    private var valuesRevision = 0

    init(capacity: Int = 60) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    func add(_ value: Double?) {
        if let oldValue = buffer[index] {
            removeValue(oldValue)
        }
        if let value {
            insert(value)
        }

        buffer[index] = value
        index = (index + 1) % capacity
        if index == 0 { isFull = true }
        cachedLatest = value
        cachedValues = nil
        valuesRevision += 1
        recalculateStatistics()
    }

    var values: [Double?] {
        orderedValues()
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

    var revision: Int {
        valuesRevision
    }

    func clear() {
        buffer = Array(repeating: nil, count: capacity)
        index = 0
        isFull = false
        sum = 0
        sumOfSquares = 0
        nonNilCount = 0
        valueCounts.removeAll(keepingCapacity: true)
        cachedValues = nil
        valuesRevision += 1
        cachedLatest = nil
        cachedAverage = nil
        cachedJitter = nil
        cachedMin = nil
        cachedMax = nil
        cachedLossPercentage = 0
    }

    private func insert(_ value: Double) {
        nonNilCount += 1
        sum += value
        sumOfSquares += value * value
        valueCounts[value, default: 0] += 1
    }

    private func removeValue(_ value: Double) {
        sum -= value
        sumOfSquares -= value * value
        nonNilCount -= 1
        let remainingCount = valueCounts[value].map { $0 - 1 } ?? -1
        if remainingCount > 0 {
            valueCounts[value] = remainingCount
        } else {
            valueCounts.removeValue(forKey: value)
        }
    }

    private func orderedValues() -> [Double?] {
        if let cachedValues {
            return cachedValues
        }

        let values = isFull
            ? Array(buffer[index...]) + Array(buffer[..<index])
            : Array(buffer[..<index])
        cachedValues = values
        return values
    }

    private func recalculateStatistics() {
        let total = isFull ? capacity : index
        let nilCount = total - nonNilCount

        guard nonNilCount > 0 else {
            cachedAverage = nil
            cachedJitter = nil
            cachedMin = nil
            cachedMax = nil
            cachedLossPercentage = total > 0 ? 100 : 0
            return
        }

        let mean = sum / Double(nonNilCount)

        cachedLossPercentage = Double(nilCount) / Double(total) * 100
        cachedMin = valueCounts.keys.min()
        cachedMax = valueCounts.keys.max()
        cachedAverage = mean
        let variance = max(0, sumOfSquares / Double(nonNilCount) - mean * mean)
        cachedJitter = nonNilCount > 1 ? variance.squareRoot() : nil
    }
}
