import SwiftUI

struct ThroughputRowView: View {
    let download: [Double?]
    let upload: [Double?]
    let downText: String
    let upText: String
    private let rowHeight: CGFloat = 34

    var body: some View {
        ZStack(alignment: .leading) {
            ThroughputGraphView(download: download, upload: upload)
                .opacity(0.65)
                .frame(height: 22)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Throughput")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(downText)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                        Text(upText)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .anchorPreference(key: ThroughputLabelBoundsKey.self, value: .bounds) { $0 }

                Spacer()
            }
            .backgroundPreferenceValue(ThroughputLabelBoundsKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        let rect = paddedRect(proxy[anchor])
                        BlurEffectView(material: .hudWindow)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
        .padding(.vertical, 4)
    }

    private func paddedRect(_ rect: CGRect) -> CGRect {
        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 6
        let maskWidth = rect.width + paddingX
        let maskHeight = min(rect.height + paddingY, rowHeight)
        return CGRect(
            x: rect.minX - paddingX / 2,
            y: rect.midY - maskHeight / 2,
            width: maskWidth,
            height: maskHeight
        )
    }
}

private struct ThroughputLabelBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
