import SwiftUI

struct MetricRowView: View {
    let label: String
    let value: String
    let color: Color
    let history: [Double?]
    var subtitle: String? = nil
    private let rowHeight: CGFloat = 34

    var body: some View {
        ZStack(alignment: .leading) {
            chartLayer(opacity: 0.65)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(color)
                        if let sub = subtitle {
                            Text(sub)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .anchorPreference(key: LabelBoundsKey.self, value: .bounds) { $0 }

                Spacer()
            }
            .backgroundPreferenceValue(LabelBoundsKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        blurPatch(rect: paddedRect(proxy[anchor]))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
        .padding(.vertical, 4)
    }

    private func chartLayer(opacity: Double) -> some View {
        SparklineView(values: history, color: color, height: 28)
            .opacity(opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

    private func blurPatch(rect: CGRect) -> some View {
        ZStack {
            BlurEffectView(material: .hudWindow)
            Color.black.opacity(0.12)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .allowsHitTesting(false)
    }
}

private struct LabelBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
