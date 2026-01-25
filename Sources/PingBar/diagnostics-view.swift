import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var viewModel: DiagnosticsViewModel
    @ObservedObject var settings: SettingsStore
    var onQuit: () -> Void
    @State private var showingSettings = false

    var body: some View {
        Group {
            if viewModel.isPopoverVisible {
                VStack(spacing: 0) {
                    ZStack {
                        mainContent
                            .rotation3DEffect(
                                .degrees(showingSettings ? 180 : 0),
                                axis: (x: 0, y: 1, z: 0),
                                perspective: 0.6
                            )
                            .opacity(showingSettings ? 0 : 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        settingsContent
                            .rotation3DEffect(
                                .degrees(showingSettings ? 0 : -180),
                                axis: (x: 0, y: 1, z: 0),
                                perspective: 0.6
                            )
                            .opacity(showingSettings ? 1 : 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .animation(.easeInOut(duration: 0.35), value: showingSettings)

                    footerBar
                }
                .frame(width: 360, height: 520)
                .background(popoverBackground)
            } else {
                Color.clear
                    .frame(width: 360, height: 520)
            }
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                networkSummary

                if viewModel.connectionStatus == .offline {
                    offlineBanner
                }

                if viewModel.connectionStatus != .offline, severeLossDetected {
                    severeLossBanner
                }

                if viewModel.isCaptivePortal {
                    captivePortalWarning
                }

                if viewModel.showLegacyWifiBanner {
                    legacyWifiBanner
                }

                if isWiredConnection {
                    routerSection
                    sectionDivider
                    internetSection
                    sectionDivider
                    dnsSection
                    sectionDivider
                    wifiSection
                } else {
                    wifiSection
                    sectionDivider
                    routerSection
                    sectionDivider
                    internetSection
                    sectionDivider
                    dnsSection
                }

            }
            .padding(12)
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsHeader
                SettingsView(diagnosticsViewModel: viewModel, settings: settings)
            }
            .padding(12)
        }
    }

    private var networkSummary: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.connectionStatus.color)
                .frame(width: 8, height: 8)

            if viewModel.connectionStatus == .offline,
               viewModel.wifiInfo == nil,
               viewModel.defaultRouteInterface == nil {
                Text("Not connected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                Text(viewModel.primaryConnectionName)
                    .font(.system(size: 13, weight: .medium))
                if let wifi = viewModel.wifiInfo, wifi.ssid == nil && !viewModel.hasLocationPermission {
                    Button(action: { viewModel.requestLocationPermission() }) {
                        Image(systemName: "location.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Grant Location Permission")
                }
            }

            Spacer()

            if let wifi = viewModel.wifiInfo {
                let standardLabel = wifi.standard.rawValue.replacingOccurrences(of: "Wi-Fi ", with: "")
                let detailLabel = wifi.standard == .unknown ? wifi.band.rawValue : "\(standardLabel) · \(wifi.band.rawValue)"
                Text(detailLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            if let wiredIcon = wiredIndicatorIcon(type: viewModel.activeConnectionType) {
                Image(systemName: wiredIcon)
                    .foregroundColor(.green)
                    .help(wiredIndicatorHelp(type: viewModel.activeConnectionType))
            }
        }
    }

    private var wifiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Wi-Fi")

            if let wifi = viewModel.wifiInfo {
                glassContainer {
                    metricRow(
                        label: "Signal",
                        value: "\(wifi.rssi) dBm",
                        color: viewModel.colorForSignal(wifi.rssi),
                        history: viewModel.wifiSignalHistory
                    )

                    metricRow(
                        label: "Noise",
                        value: "\(wifi.noise) dBm",
                        color: viewModel.colorForNoise(wifi.noise),
                        history: viewModel.wifiNoiseHistory
                    )

                    metricRow(
                        label: "Link Rate",
                        value: formatMbps(wifi.linkRate),
                        color: viewModel.colorForRate(wifi.linkRate, band: wifi.band),
                        history: viewModel.wifiRateHistory
                    )
                }
            } else {
                Text("Connect to Wi-Fi to see signal details.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var routerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderInline("Router", trailingText: viewModel.gatewayIP)

            glassContainer {
                metricRow(
                    label: "Ping",
                    value: formatLatency(viewModel.routerLatency),
                    color: viewModel.colorForPing(viewModel.routerLatency),
                    history: viewModel.routerHistory
                )

                metricRow(
                    label: "Jitter",
                    value: formatLatency(viewModel.routerJitter),
                    color: viewModel.colorForJitter(viewModel.routerJitter),
                    history: viewModel.routerJitterHistory
                )

                metricRow(
                    label: "Loss",
                    value: formatLoss(viewModel.routerLoss),
                    color: viewModel.colorForLoss(viewModel.routerLoss),
                    history: viewModel.routerLossHistory
                )
            }
        }
    }

    private var internetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderInline("Internet", trailingText: "Connected to \(settings.internetPingTarget)")

            glassContainer {
                metricRow(
                    label: "Ping",
                    value: formatLatency(viewModel.internetLatency),
                    color: viewModel.colorForPing(viewModel.internetLatency),
                    history: viewModel.internetHistory
                )
                ThroughputRowView(
                    download: viewModel.downloadRateHistory,
                    upload: viewModel.uploadRateHistory,
                    downText: "↓\(formatRate(viewModel.currentDownloadRate))",
                    upText: "↑\(formatRate(viewModel.currentUploadRate))"
                )

                metricRow(
                    label: "Jitter",
                    value: formatLatency(viewModel.internetJitter),
                    color: viewModel.colorForJitter(viewModel.internetJitter),
                    history: viewModel.internetJitterHistory
                )

                metricRow(
                    label: "Loss",
                    value: formatLoss(viewModel.internetLoss),
                    color: viewModel.colorForLoss(viewModel.internetLoss),
                    history: viewModel.internetLossHistory
                )
            }
        }
    }

    private var dnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "DNS",
                subtitle: dnsSubtitle,
                trailing: {
                    Button(action: viewModel.openNetworkSettings) {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            )

            glassContainer {
                metricRow(
                    label: "Lookup",
                    value: formatLatency(viewModel.dnsLatency),
                    color: viewModel.colorForDns(viewModel.dnsLatency),
                    history: viewModel.dnsHistory
                )
            }
        }
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 4)
    }

    private var captivePortalWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Captive Portal Detected")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("This network requires login. Open a browser to authenticate.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Button(action: { viewModel.openCaptivePortalLogin() }) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("Open Login Page")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private var legacyWifiBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundColor(.orange)
                Text("Older Wi-Fi standard")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("This network is using an older Wi-Fi mode on 2.4 GHz. Try 5 GHz if available.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var offlineBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .foregroundColor(.red)
                Text("No network connection")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Check Wi‑Fi or Ethernet and try reconnecting.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    private var severeLossBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.orange)
                Text("High packet loss detected")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Try moving closer to the router or checking ISP stability.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var severeLossDetected: Bool {
        viewModel.routerLoss >= 10 || viewModel.internetLoss >= 10
    }

    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private func sectionHeader<T: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            trailing()
        }
    }

    private func sectionHeaderInline(_ title: String, trailingText: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    private var isWiredConnection: Bool {
        switch viewModel.activeConnectionType {
        case .ethernet, .thunderbolt, .other:
            return true
        case .wifi:
            return false
        }
    }

    private func wiredIndicatorIcon(type: ActiveConnectionType) -> String? {
        switch type {
        case .ethernet:
            return "cable.connector"
        case .thunderbolt:
            return "bolt.horizontal.circle.fill"
        case .other:
            return "network"
        case .wifi:
            return nil
        }
    }

    private func wiredIndicatorHelp(type: ActiveConnectionType) -> String {
        switch type {
        case .ethernet:
            return "Routed over Ethernet"
        case .thunderbolt:
            return "Routed over Thunderbolt"
        case .other(let name):
            return name ?? "Routed over wired network"
        case .wifi:
            return "Routed over Wi-Fi"
        }
    }

    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                content()
            }
        } else {
            content()
        }
    }

    private var popoverBackground: some View {
        Group {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            ZStack {
                shape.fill(Color(NSColor.windowBackgroundColor))
                shape.stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button(action: { withAnimation { showingSettings.toggle() } }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(showingSettings ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "Back to Overview" : "Settings")

            Spacer()

            Button(action: onQuit) {
                Image(systemName: "power")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.secondary.opacity(0.15)),
            alignment: .top
        )
    }

    private func metricRow(
        label: String,
        value: String,
        color: Color,
        history: [Double?],
        subtitle: String? = nil
    ) -> some View {
        MetricRowView(
            label: label,
            value: value,
            color: color,
            history: history,
            subtitle: subtitle
        )
    }

    private var dnsSubtitle: String {
        if let first = viewModel.dnsServers.first {
            return "Router assigned (\(first))"
        }
        return "Router assigned"
    }

    private func formatLatency(_ ms: Double?) -> String {
        guard let ms = ms else { return "---" }
        if ms >= 1000 {
            return String(format: "%.1fs", ms / 1000)
        }
        return "\(Int(ms.rounded()))ms"
    }

    private func formatLoss(_ loss: Double) -> String {
        String(format: "%.1f%%", loss)
    }

    private func formatRate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "---" }
        let bitsPerSecond = bytesPerSecond * 8
        if bitsPerSecond >= 1_000_000_000 {
            return String(format: "%.1f Gbps", bitsPerSecond / 1_000_000_000)
        }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        }
        if bitsPerSecond >= 1_000 {
            return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
        }
        return String(format: "%.0f bps", bitsPerSecond)
    }


    private func formatMbps(_ mbps: Double) -> String {
        if mbps >= 1000 {
            return String(format: "%.1fGbps", mbps / 1000)
        }
        if mbps >= 100 {
            return String(format: "%.0f Mbps", mbps)
        }
        if mbps >= 10 {
            return String(format: "%.1f Mbps", mbps)
        }
        return String(format: "%.2f Mbps", mbps)
    }
}
