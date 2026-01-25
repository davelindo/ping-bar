import SwiftUI

struct ThroughputGraphView: View {
    let download: [Double?]
    let upload: [Double?]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if let stats = combinedStats(), stats.count > 1 {
                let range = max(stats.max - stats.min, 1)

                let downloadPoints = chartPoints(values: download, size: size, minVal: stats.min, range: range)
                let uploadPoints = chartPoints(values: upload, size: size, minVal: stats.min, range: range)

                if downloadPoints.count > 1 {
                    let fill = fillPath(points: downloadPoints, height: size.height)
                    fill
                        .fill(
                            LinearGradient(
                                colors: [Color.secondary.opacity(0.12), Color.secondary.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    linePath(points: downloadPoints)
                        .stroke(Color.secondary.opacity(0.65), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }

                if uploadPoints.count > 1 {
                    linePath(points: uploadPoints)
                        .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            } else {
                Color.clear
            }
        }
    }

    private func combinedStats() -> (min: Double, max: Double, count: Int)? {
        var minVal = Double.greatestFiniteMagnitude
        var maxVal = -Double.greatestFiniteMagnitude
        var nonNilCount = 0

        for value in download {
            guard let value else { continue }
            minVal = min(minVal, value)
            maxVal = max(maxVal, value)
            nonNilCount += 1
        }

        for value in upload {
            guard let value else { continue }
            minVal = min(minVal, value)
            maxVal = max(maxVal, value)
            nonNilCount += 1
        }

        guard nonNilCount > 0 else { return nil }
        return (min: minVal, max: maxVal, count: nonNilCount)
    }

    private func chartPoints(values: [Double?], size: CGSize, minVal: Double, range: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let width = size.width
        let stepX = width / CGFloat(max(values.count - 1, 1))

        return values.enumerated().compactMap { index, value in
            guard let val = value else { return nil }
            let x = CGFloat(index) * stepX
            let normalizedY = (val - minVal) / range
            let y = size.height - (CGFloat(normalizedY) * size.height * 0.8 + size.height * 0.1)
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func fillPath(points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
        }
    }
}
