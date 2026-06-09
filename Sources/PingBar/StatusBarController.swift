import Cocoa
import Combine
import SwiftUI

@MainActor
class StatusBarController: NSObject, NSPopoverDelegate {
    private struct ThroughputSnapshot {
        let timestamp: Date
        let down: Double
        let up: Double
    }

    private var statusItem: NSStatusItem
    private let diagnosticsService = DiagnosticsService()
    private var popover: NSPopover!
    private var viewModel: DiagnosticsViewModel!
    private let settings = SettingsStore()
    private var cancellables = Set<AnyCancellable>()
    private var isPopoverVisible = false
    private var displayView: StatusItemDisplayView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let statusBarThroughputInterval: TimeInterval = 4.0
    private var statusBarThroughputSample: ThroughputSnapshot?
    private var statusBarThroughputRate: (down: Double, up: Double)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupStatusItem()
        setupPopover()
        setupDiagnosticsService()
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")

            let displayView = StatusItemDisplayView()
            displayView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(displayView)
            NSLayoutConstraint.activate([
                displayView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                displayView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                displayView.topAnchor.constraint(equalTo: button.topAnchor),
                displayView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            self.displayView = displayView
            updateDisplay(latency: nil)
        }
    }

    private func setupPopover() {
        viewModel = DiagnosticsViewModel(service: diagnosticsService)

        let diagnosticsView = DiagnosticsView(
            viewModel: viewModel,
            settings: settings,
            onQuit: { [weak self] in
                self?.quit()
            }
        )

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 560)
        popover.contentViewController = NSHostingController(rootView: diagnosticsView)
        popover.delegate = self
    }

    private func setupDiagnosticsService() {
        diagnosticsService.updateInternetTarget(settings.internetPingTarget)
        diagnosticsService.updateDnsHostname(settings.dnsLookupHost)
        diagnosticsService.setSamplingInterval(settings.samplingIntervalClosed, tickImmediately: false)
        diagnosticsService.setDataUsageHistoryEnabled(settings.isDataUsageHistoryEnabled)
        diagnosticsService.setPerNetworkUsageEnabled(settings.isPerNetworkUsageEnabled)
        diagnosticsService.setDataUsageRetentionDays(settings.dataUsageRetentionDays)

        settings.$internetPingTarget
            .removeDuplicates()
            .sink { [weak self] target in
                self?.diagnosticsService.updateInternetTarget(target)
            }
            .store(in: &cancellables)

        settings.$dnsLookupHost
            .removeDuplicates()
            .sink { [weak self] host in
                self?.diagnosticsService.updateDnsHostname(host)
            }
            .store(in: &cancellables)

        settings.$samplingIntervalOpen
            .removeDuplicates()
            .sink { [weak self] interval in
                guard let self = self, self.isPopoverVisible else { return }
                self.diagnosticsService.setSamplingInterval(interval, tickImmediately: false)
            }
            .store(in: &cancellables)

        settings.$samplingIntervalClosed
            .removeDuplicates()
            .sink { [weak self] interval in
                guard let self = self, !self.isPopoverVisible else { return }
                self.diagnosticsService.setSamplingInterval(interval, tickImmediately: false)
            }
            .store(in: &cancellables)

        settings.$statusBarDisplayMode
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.resetStatusBarThroughputSample()
                self?.updateDisplay(latency: self?.diagnosticsService.internetHistory.latest)
            }
            .store(in: &cancellables)

        bindDataUsageSetting(settings.$isDataUsageHistoryEnabled) { service, enabled in
            service.setDataUsageHistoryEnabled(enabled)
        }

        bindDataUsageSetting(settings.$isPerNetworkUsageEnabled) { service, enabled in
            service.setPerNetworkUsageEnabled(enabled)
        }

        bindDataUsageSetting(settings.$dataUsageRetentionDays) { service, days in
            service.setDataUsageRetentionDays(days)
        }

        diagnosticsService.onUpdate = { [weak self] in
            guard let self = self else { return }
            let latency = self.diagnosticsService.isRunning ? self.diagnosticsService.internetHistory.latest : nil
            self.updateDisplay(latency: latency)
            if self.isPopoverVisible {
                self.viewModel.refresh()
            }
        }
        diagnosticsService.start()
    }

    private func bindDataUsageSetting<Value: Equatable>(
        _ publisher: Published<Value>.Publisher,
        apply: @escaping (DiagnosticsService, Value) -> Void
    ) {
        publisher
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self else { return }
                apply(self.diagnosticsService, value)
                self.viewModel.refresh()
            }
            .store(in: &cancellables)
    }

    private func updateDisplay(latency: Double?) {
        guard let displayView else { return }

        switch settings.statusBarDisplayMode {
        case .latency:
            displayView.updateLatency(text: latencyDisplayText(latency), color: latencyDisplayColor(latency))
        case .throughput:
            let throughputRates = diagnosticsService.isRunning ? statusBarThroughputRates() : nil
            let downText = throughputRates.map { compactRateString($0.down) } ?? "--"
            let upText = throughputRates.map { compactRateString($0.up) } ?? "--"
            displayView.updateThroughput(down: "↓\(downText)", up: "↑\(upText)")
        }

        statusItem.length = max(1, displayView.intrinsicContentSize.width)
    }

    private func latencyDisplayText(_ latency: Double?) -> String {
        guard diagnosticsService.isRunning, let ms = latency else {
            return "---"
        }
        if ms >= 1000 {
            return String(format: "%.1fs", ms / 1000)
        }
        return "\(Int(ms.rounded()))ms"
    }

    private func latencyDisplayColor(_ latency: Double?) -> NSColor {
        guard diagnosticsService.isRunning, let latency else {
            return .secondaryLabelColor
        }
        return colorForLatency(latency)
    }

    private func resetStatusBarThroughputSample() {
        statusBarThroughputSample = nil
        statusBarThroughputRate = nil
    }

    private func statusBarThroughputRates(now: Date = Date()) -> (down: Double, up: Double)? {
        guard let totalDown = diagnosticsService.totalDownloaded,
              let totalUp = diagnosticsService.totalUploaded else {
            resetStatusBarThroughputSample()
            return nil
        }

        guard let sample = statusBarThroughputSample else {
            statusBarThroughputSample = ThroughputSnapshot(timestamp: now, down: totalDown, up: totalUp)
            return nil
        }

        if totalDown < sample.down || totalUp < sample.up {
            statusBarThroughputSample = ThroughputSnapshot(timestamp: now, down: totalDown, up: totalUp)
            statusBarThroughputRate = nil
            return nil
        }

        let elapsed = now.timeIntervalSince(sample.timestamp)
        guard elapsed > 0 else {
            return statusBarThroughputRate
        }
        guard elapsed >= statusBarThroughputInterval else {
            return statusBarThroughputRate
        }

        let downRate = (totalDown - sample.down) / elapsed
        let upRate = (totalUp - sample.up) / elapsed
        statusBarThroughputRate = (down: downRate, up: upRate)
        statusBarThroughputSample = ThroughputSnapshot(timestamp: now, down: totalDown, up: totalUp)
        return statusBarThroughputRate
    }

    private func colorForLatency(_ ms: Double) -> NSColor {
        .labelColor
    }

    private func compactRateString(_ bytesPerSecond: Double) -> String {
        let bitsPerSecond = max(0, bytesPerSecond) * 8
        let value: Double
        let suffix: String

        if bitsPerSecond >= 1_000_000_000 {
            value = bitsPerSecond / 1_000_000_000
            suffix = "G"
        } else if bitsPerSecond >= 1_000_000 {
            value = bitsPerSecond / 1_000_000
            suffix = "M"
        } else if bitsPerSecond >= 1_000 {
            value = bitsPerSecond / 1_000
            suffix = "K"
        } else {
            value = bitsPerSecond
            suffix = "b"
        }

        let formatted: String
        if value >= 100 {
            formatted = String(format: "%.0f", value)
        } else if value >= 10 {
            formatted = String(format: "%.1f", value)
        } else {
            formatted = String(format: "%.2f", value)
        }
        return "\(formatted)\(suffix)"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.close()
        } else {
            setPopoverVisible(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func quit() {
        diagnosticsService.stop()
        NSApp.terminate(nil)
    }

    func shutdown() {
        diagnosticsService.shutdown()
    }

    func popoverDidClose(_ notification: Notification) {
        setPopoverVisible(false)
    }

    private func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        viewModel.isPopoverVisible = visible
        diagnosticsService.setDetailedSamplingEnabled(visible)
        let interval = visible ? settings.samplingIntervalOpen : settings.samplingIntervalClosed
        diagnosticsService.setSamplingInterval(interval, tickImmediately: visible)
        if visible {
            viewModel.refresh()
            startEventMonitor()
        } else {
            stopEventMonitor()
        }
    }

    private func startEventMonitor() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                if self.popover.isShown {
                    let popoverWindow = self.popover.contentViewController?.view.window
                    if event.window !== popoverWindow {
                        self.popover.close()
                    }
                }
                return event
            }
        }

        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.close()
            }
        }
    }

    private func stopEventMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
}

private final class StatusItemDisplayView: NSView {
    private let latencyLabel = NSTextField(labelWithString: "")
    private let downLabel = NSTextField(labelWithString: "")
    private let upLabel = NSTextField(labelWithString: "")
    private let stack: NSStackView

    override init(frame frameRect: NSRect) {
        stack = NSStackView(views: [downLabel, upLabel])
        super.init(frame: frameRect)

        latencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        latencyLabel.alignment = .center

        downLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        downLabel.alignment = .center
        upLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        upLabel.alignment = .center

        stack.orientation = .vertical
        stack.spacing = -1
        stack.alignment = .centerX

        latencyLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(latencyLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            latencyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            latencyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateLatency(text: "---", color: .secondaryLabelColor)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let content = latencyLabel.isHidden ? stack.fittingSize : latencyLabel.fittingSize
        return NSSize(width: content.width + 2, height: content.height + 2)
    }

    func updateLatency(text: String, color: NSColor) {
        latencyLabel.stringValue = text
        latencyLabel.textColor = color
        latencyLabel.isHidden = false
        stack.isHidden = true
        invalidateIntrinsicContentSize()
    }

    func updateThroughput(down: String, up: String) {
        downLabel.stringValue = down
        upLabel.stringValue = up
        downLabel.textColor = .labelColor
        upLabel.textColor = .secondaryLabelColor
        latencyLabel.isHidden = true
        stack.isHidden = false
        invalidateIntrinsicContentSize()
    }
}
