import AppKit
import SwiftUI

struct IntegratedScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        tuneScroller(scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let hostingView = nsView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
        } else {
            nsView.documentView = NSHostingView(rootView: content)
        }
        tuneScroller(nsView)
    }

    private func tuneScroller(_ scrollView: NSScrollView) {
        scrollView.verticalScroller?.knobStyle = .dark
        scrollView.verticalScroller?.alphaValue = 0.18
    }
}
