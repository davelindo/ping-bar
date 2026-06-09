import SwiftUI

private enum HistoryScope: String, CaseIterable, Identifiable {
    case all = "All"
    case ssid = "SSID"

    var id: String { rawValue }
}

private enum DiagnosticsFace: Hashable {
    case overview
    case settings
    case history
}

struct DiagnosticsView: View {
    @ObservedObject var viewModel: DiagnosticsViewModel
    @ObservedObject var settings: SettingsStore
    var onQuit: () -> Void
    @State private var face: DiagnosticsFace = .overview
    @State private var historyScope: HistoryScope = .all

    var body: some View {
        Group {
            if viewModel.isPopoverVisible {
                VStack(spacing: 0) {
                    activeContent
                        .id(face)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity
                        ))
                        .animation(.easeInOut(duration: 0.25), value: face)

                    footerBar
                }
                .frame(width: 390, height: 560)
                .background(popoverBackground)
                .preferredColorScheme(.dark)
            } else {
                Color.clear
                    .frame(width: 390, height: 560)
            }
        }
        .onChange(of: viewModel.isPopoverVisible) { visible in
            if !visible {
                face = .overview
                historyScope = .all
            }
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        switch face {
        case .overview:
            mainContent
        case .settings:
            settingsContent
        case .history:
            historyContent
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                networkSummary
                healthOverview
                dataUsageSection

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

                internetSection
                wifiSection
                dnsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsHeader
                SettingsView(diagnosticsViewModel: viewModel, settings: settings)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
    }

    private var historyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                historyHeader
                historySummary
                historyRecords
                topNetworksSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
    }

    private var networkSummary: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(viewModel.connectionStatus.color)
                .frame(width: 20, height: 20)

            if viewModel.connectionStatus == .offline,
               viewModel.wifiInfo == nil,
               viewModel.defaultRouteInterface == nil {
                Text("Not connected")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.secondary)
            } else {
                Text(viewModel.primaryConnectionName)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                if let wifi = viewModel.wifiInfo, wifi.ssid == nil && !viewModel.hasLocationPermission {
                    Button(action: { viewModel.requestLocationPermission() }) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 14)
                    .background(Color.secondary.opacity(0.24), in: Capsule())
                    .help("Grant Location Permission")
                }
            }

            Spacer()

            if let wifi = viewModel.wifiInfo {
                let detailLabel = wifiDetailLabel(wifi)
                Text(detailLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(panelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let wiredIcon = wiredIndicatorIcon(type: viewModel.activeConnectionType) {
                Image(systemName: wiredIcon)
                    .foregroundColor(.green)
                    .help(wiredIndicatorHelp(type: viewModel.activeConnectionType))
            }

            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(face == .settings ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(face == .settings ? "Back to Overview" : "Settings")
            .accessibilityLabel(face == .settings ? "Back to overview" : "Settings")
        }
        .frame(height: 46)
    }

    private var dataUsageSection: some View {
        sectionPanel("Data Usage") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Overall")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(formatBytes(viewModel.dataUsage.overall.total))
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        transferSplit(viewModel.dataUsage.overall)
                        Text("Today \(formatBytes(viewModel.dataUsage.today.total))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Divider().opacity(0.45)

                if settings.isDataUsageHistoryEnabled {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(settings.isPerNetworkUsageEnabled ? (viewModel.dataUsage.currentNetworkName ?? "Current Network") : "Per-SSID totals off")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(settings.isPerNetworkUsageEnabled ? "\(formatBytes(viewModel.dataUsage.currentNetworkTotals?.total ?? 0)) on this network" : "Overall usage is still recorded")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button(action: showHistory) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Data History")
                        .accessibilityLabel("Data history")
                    }
                } else {
                    Text("Usage history is off")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                if settings.isPerNetworkUsageEnabled {
                    ForEach(Array(viewModel.dataUsage.networks.prefix(2))) { network in
                        usageListRow(title: network.name, totals: network.totals)
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var healthOverview: some View {
        HStack(spacing: 8) {
            healthTile(
                title: "Internet",
                value: formatLatency(viewModel.internetLatency),
                icon: "globe",
                color: viewModel.colorForPing(viewModel.internetLatency)
            )
            healthTile(
                title: "Router",
                value: formatLatency(viewModel.routerLatency),
                icon: "wifi.router",
                color: viewModel.colorForPing(viewModel.routerLatency)
            )
            healthTile(
                title: "Loss",
                value: formatLoss(viewModel.internetLoss),
                icon: "waveform.path.ecg",
                color: viewModel.colorForLoss(viewModel.internetLoss)
            )
        }
    }

    private func healthTile(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var wifiSection: some View {
        sectionPanel("Wi-Fi") {
            if let wifi = viewModel.wifiInfo {
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
            } else {
                Text("Connect to Wi-Fi to see signal details.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var routerSection: some View {
        sectionPanel("Router", trailingText: viewModel.gatewayIP) {
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

    private var internetSection: some View {
        sectionPanel("Internet") {
            metricRow(
                label: "Ping",
                value: formatLatency(viewModel.internetLatency),
                color: viewModel.colorForPing(viewModel.internetLatency),
                history: viewModel.internetHistory
            )
            ThroughputRowView(
                download: viewModel.downloadRateHistory,
                upload: viewModel.uploadRateHistory,
                downText: "↓ \(formatRate(viewModel.currentDownloadRate))",
                upText: "↑ \(formatRate(viewModel.currentUploadRate))"
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

    private var dnsSection: some View {
        sectionPanel("DNS") {
            metricRow(
                label: "Lookup",
                value: formatLatency(viewModel.dnsLatency),
                color: viewModel.colorForDns(viewModel.dnsLatency),
                history: viewModel.dnsHistory
            )

            HStack(spacing: 12) {
                Text("Target")
                    .font(.system(size: 14, weight: .regular))
                Text(settings.dnsLookupHost)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 40)
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

    private func sectionPanel<Content: View>(
        _ title: String,
        trailingText: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()
                .opacity(0.55)
                .padding(.horizontal, 12)

            content()
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
        }
        .background(panelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
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

    private var historyHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Data History")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Picker("History scope", selection: $historyScope) {
                ForEach(availableHistoryScopes) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 118)
            .accessibilityLabel("History scope")
        }
    }

    private var historySummary: some View {
        HStack(spacing: 8) {
            historySummaryItem("Overall", value: formatBytes(viewModel.dataUsage.overall.total))
            historySummaryItem("Today", value: formatBytes(viewModel.dataUsage.today.total))
            if settings.isPerNetworkUsageEnabled {
                historySummaryItem("This SSID", value: formatBytes(viewModel.dataUsage.currentNetworkTotals?.total ?? 0))
            }
        }
    }

    private func historySummaryItem(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var historyRecords: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Last \(viewModel.dataUsage.retentionDays) days", systemImage: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Label(historyScope == .all ? "All traffic" : "Current SSID", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().opacity(0.5)

            if filteredHistoryRecords.isEmpty {
                Text("No transfer records yet.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ForEach(filteredHistoryRecords) { record in
                    historyRecordRow(record)
                }
            }
        }
        .background(panelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
    }

    private func historyRecordRow(_ record: DataUsageDailyRecord) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayDay(record.day))
                    .font(.system(size: 12, weight: .semibold))
                Text(record.networkName ?? "Unknown")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 100, alignment: .leading)

            Spacer(minLength: 4)

            Text("↓ \(formatBytes(record.totals.downloaded))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.blue)
                .lineLimit(1)
            Text("↑ \(formatBytes(record.totals.uploaded))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.purple)
                .lineLimit(1)
            Text(formatBytes(record.totals.total))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.secondary.opacity(0.12)),
            alignment: .bottom
        )
    }

    private var topNetworksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top Networks")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider().opacity(0.5)
                .padding(.horizontal, 12)

            if viewModel.dataUsage.networks.isEmpty {
                Text("No SSID totals yet.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
            } else {
                ForEach(viewModel.dataUsage.networks) { network in
                    usageListRow(title: network.name, totals: network.totals)
                        .padding(.horizontal, 12)
                }
            }
        }
        .background(panelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
    }

    private var filteredHistoryRecords: [DataUsageDailyRecord] {
        switch historyScope {
        case .all:
            return viewModel.dataUsage.overallDailyRecords
        case .ssid:
            guard settings.isPerNetworkUsageEnabled,
                  let currentName = viewModel.dataUsage.currentNetworkName else {
                return []
            }
            return viewModel.dataUsage.networkDailyRecords.filter { $0.networkName == currentName }
        }
    }

    private var availableHistoryScopes: [HistoryScope] {
        if settings.isPerNetworkUsageEnabled, viewModel.dataUsage.currentNetworkName != nil {
            return [.all, .ssid]
        }
        return [.all]
    }

    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
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
                shape.fill(Color(red: 0.12, green: 0.12, blue: 0.13))
                shape.stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var panelFill: some ShapeStyle {
        Color(red: 0.16, green: 0.16, blue: 0.17)
    }

    private var footerBar: some View {
        HStack {
            if face != .overview {
                Button(action: showOverview) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back to overview")
            } else {
                Button(action: showSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")

                Button(action: showHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Data History")
                .accessibilityLabel("Data history")
            }

            Spacer()

            Text(footerTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit")
            .accessibilityLabel("Quit PingBar")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.15))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    private func showOverview() {
        withAnimation {
            face = .overview
        }
    }

    private func showSettings() {
        withAnimation {
            face = .settings
        }
    }

    private func showHistory() {
        withAnimation {
            if !availableHistoryScopes.contains(historyScope) {
                historyScope = .all
            }
            face = .history
        }
    }

    private var footerTitle: String {
        switch face {
        case .overview:
            return "Updated now"
        case .settings:
            return "Settings"
        case .history:
            return "History"
        }
    }

    private func wifiDetailLabel(_ wifi: WiFiInfo) -> String {
        let standardLabel = wifi.standard.rawValue.replacingOccurrences(of: "Wi-Fi ", with: "")
        if wifi.standard == .unknown {
            return wifi.band.rawValue
        }
        return "\(standardLabel) • \(wifi.band.rawValue)"
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

    private func usageListRow(title: String, totals: DataUsageTotals) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(formatBytes(totals.total))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(height: 24)
    }

    private func transferSplit(_ totals: DataUsageTotals) -> some View {
        HStack(spacing: 8) {
            Text("↓ \(formatBytes(totals.downloaded))")
                .foregroundColor(.blue)
            Text("↑ \(formatBytes(totals.uploaded))")
                .foregroundColor(.purple)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .lineLimit(1)
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
            return String(format: "%.1f s", ms / 1000)
        }
        return "\(Int(ms.rounded())) ms"
    }

    private func formatLoss(_ loss: Double) -> String {
        if loss.rounded() == loss {
            return "\(Int(loss))%"
        }
        return String(format: "%.1f%%", loss)
    }

    private func formatRate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "---" }
        let bitsPerSecond = bytesPerSecond * 8
        if bitsPerSecond >= 1_000_000_000 {
            return String(format: "%.1f Gbps", bitsPerSecond / 1_000_000_000)
        }
        if bitsPerSecond >= 1_000_000 {
            let mbps = bitsPerSecond / 1_000_000
            if mbps >= 100 || mbps.rounded() == mbps {
                return String(format: "%.0f Mbps", mbps)
            }
            return String(format: "%.1f Mbps", mbps)
        }
        if bitsPerSecond >= 1_000 {
            return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
        }
        return String(format: "%.0f bps", bitsPerSecond)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 {
            return String(format: "%.1f GB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1f MB", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f KB", value / 1_000)
        }
        return "\(bytes) B"
    }

    private func displayDay(_ day: String) -> String {
        guard let date = Self.dayFormatter.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        return Self.displayDayFormatter.string(from: date)
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
