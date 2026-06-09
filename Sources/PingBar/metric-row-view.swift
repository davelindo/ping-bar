import SwiftUI

struct MetricRowView: View {
    let label: String
    let value: String
    let color: Color
    let history: [Double?]
    var subtitle: String? = nil
    private let rowHeight: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(width: 94, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 92, alignment: .leading)

            Spacer(minLength: 4)

            SparklineView(
                values: history,
                color: color,
                height: 22,
                lineWidth: 1.3,
                lineOpacity: 0.86,
                fillOpacity: 0.11
            )
            .frame(minWidth: 68)
            .accessibilityHidden(true)
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .combine)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.secondary.opacity(0.14)),
            alignment: .bottom
        )
    }
}
