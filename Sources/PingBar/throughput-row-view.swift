import SwiftUI

struct ThroughputRowView: View {
    let download: [Double?]
    let upload: [Double?]
    let downText: String
    let upText: String
    private let rowHeight: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            Text("Throughput")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(width: 84, alignment: .leading)

            HStack(spacing: 6) {
                Text(downText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(upText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.purple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 142, alignment: .leading)

            Spacer(minLength: 4)

            ThroughputGraphView(download: download, upload: upload)
                .frame(minWidth: 68, maxWidth: .infinity, minHeight: 24, maxHeight: 24)
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
