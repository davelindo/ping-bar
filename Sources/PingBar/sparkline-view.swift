import SwiftUI

struct SparklineView: View {
    let values: [Double?]
    let color: Color
    let height: CGFloat
    let lineWidth: CGFloat
    let lineOpacity: Double
    let fillOpacity: Double

    init(
        values: [Double?],
        color: Color = .blue,
        height: CGFloat = 24,
        lineWidth: CGFloat = 2.0,
        lineOpacity: Double = 0.65,
        fillOpacity: Double = 0.18
    ) {
        self.values = values
        self.color = color
        self.height = height
        self.lineWidth = lineWidth
        self.lineOpacity = lineOpacity
        self.fillOpacity = fillOpacity
    }

    var body: some View {
        GeometryReader { geometry in
            let points = chartPoints(size: geometry.size)
            if points.count > 1 {
                let line = linePath(points: points)
                let fill = fillPath(points: points, height: geometry.size.height)

                fill
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(fillOpacity), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                line
                    .stroke(
                        color.opacity(lineOpacity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            } else {
                Color.clear
            }
        }
        .frame(height: height)
    }

    private func chartPoints(size: CGSize) -> [CGPoint] {
        var indexedValues: [(Int, Double)] = []
        indexedValues.reserveCapacity(values.count)
        var minVal = Double.greatestFiniteMagnitude
        var maxVal = -Double.greatestFiniteMagnitude

        for (index, value) in values.enumerated() {
            guard let value else { continue }
            indexedValues.append((index, value))
            minVal = min(minVal, value)
            maxVal = max(maxVal, value)
        }

        guard indexedValues.count > 1 else { return [] }

        let range = max(maxVal - minVal, 1)
        let width = size.width
        let stepX = width / CGFloat(max(values.count - 1, 1))

        return indexedValues.map { index, value in
            let x = CGFloat(index) * stepX
            let normalizedY = (value - minVal) / range
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
