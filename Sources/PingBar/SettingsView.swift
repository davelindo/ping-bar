import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var diagnosticsViewModel: DiagnosticsViewModel
    @ObservedObject var settings: SettingsStore
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("General")

            settingsToggle(
                "Launch at Login",
                isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                )
            )

            Divider()

            sectionHeader("Diagnostics")

            VStack(alignment: .leading, spacing: 10) {
                settingsRow("Menu bar display") {
                    Picker("Menu bar display", selection: $settings.statusBarDisplayMode) {
                        ForEach(StatusBarDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 136)
                    .accessibilityLabel("Menu bar display")
                }

                settingsRow("Internet ping target") {
                    TextField(SettingsStore.defaultInternetPingTarget, text: $settings.internetPingTarget)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 136)
                }

                settingsRow("DNS lookup host") {
                    TextField(SettingsStore.defaultDnsLookupHost, text: $settings.dnsLookupHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 136)
                }

                samplingPicker(
                    title: "Sampling interval (open)",
                    values: [1, 2, 5, 10, 15, 30],
                    selection: intervalBinding(for: \.samplingIntervalOpen)
                )

                samplingPicker(
                    title: "Sampling interval (closed)",
                    values: [5, 10, 15, 30, 60],
                    selection: intervalBinding(for: \.samplingIntervalClosed)
                )
            }

            Divider()

            sectionHeader("Data Usage")

            VStack(alignment: .leading, spacing: 10) {
                settingsToggle("Record Usage History", isOn: $settings.isDataUsageHistoryEnabled)

                settingsToggle("Per-SSID Totals", isOn: $settings.isPerNetworkUsageEnabled)
                    .disabled(!settings.isDataUsageHistoryEnabled)

                settingsRow("History retention") {
                    Picker("History retention", selection: $settings.dataUsageRetentionDays) {
                        Text("7d").tag(7)
                        Text("30d").tag(30)
                        Text("90d").tag(90)
                        Text("1y").tag(365)
                    }
                    .labelsHidden()
                    .frame(width: 84)
                    .disabled(!settings.isDataUsageHistoryEnabled)
                    .accessibilityLabel("History retention")
                }

                settingsRow("Stored records") {
                    Button(action: diagnosticsViewModel.clearDataUsageHistory) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .help("Clear Data Usage History")
                    .accessibilityLabel("Clear data usage history")
                }
            }

            Divider()

            speedTestSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: isOn)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
    }

    private func settingsRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: 170, alignment: .leading)
            Spacer(minLength: 0)
            control()
        }
        .frame(height: 28)
    }

    private func intervalBinding(for keyPath: ReferenceWritableKeyPath<SettingsStore, Double>) -> Binding<Int> {
        Binding(
            get: { Int(settings[keyPath: keyPath].rounded()) },
            set: { settings[keyPath: keyPath] = Double($0) }
        )
    }

    private func samplingPicker(title: String, values: [Int], selection: Binding<Int>) -> some View {
        settingsRow(title) {
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text("\(value)s").tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 84)
            .accessibilityLabel(title)
        }
    }

    private var speedTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .semibold))
                Text("Speed Test")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if case .running = diagnosticsViewModel.speedTestState {
                    Button(action: diagnosticsViewModel.cancelSpeedTest) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel Speed Test")
                }
            }

            switch diagnosticsViewModel.speedTestState {
            case .idle, .cancelled:
                HStack(spacing: 10) {
                    Button(action: diagnosticsViewModel.runSpeedTest) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .help("Run Speed Test")

                    Text("Run a quick throughput check")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            case .running(let phase):
                HStack(spacing: 8) {
                    ProgressView()
                    Text(phase.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            case .completed(let result):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        speedValue(title: "Download", value: formatMbps(result.downloadMbps))
                        speedValue(title: "Upload", value: formatMbps(result.uploadMbps))
                        Spacer()
                        Button(action: diagnosticsViewModel.runSpeedTest) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Retest")
                    }

                    Text("Provider: \(result.provider)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text("Lag under load: \(lagSummary(result))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(lagColor(result.lagRating))
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Speed test failed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                        Spacer()
                        Button(action: diagnosticsViewModel.runSpeedTest) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Try Again")
                    }
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func speedValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
        }
    }

    private func lagSummary(_ result: SpeedTestResult) -> String {
        if let idle = result.idleLatencyMs, let loaded = result.loadedLatencyMs {
            let delta = max(0, loaded - idle)
            return "\(result.lagRating.label) (\(Int(loaded.rounded())) ms, +\(Int(delta.rounded())) ms)"
        }
        if let responsiveness = result.responsiveness {
            return "\(result.lagRating.label) (\(Int(responsiveness.rounded())) RPM)"
        }
        return result.lagRating.label
    }

    private func lagColor(_ rating: LagRating) -> Color {
        switch rating {
        case .low: return .green
        case .moderate: return .orange
        case .high: return .red
        case .unknown: return .secondary
        }
    }

    private func formatMbps(_ mbps: Double) -> String {
        if mbps >= 100 {
            return String(format: "%.0f Mbps", mbps)
        }
        if mbps >= 10 {
            return String(format: "%.1f Mbps", mbps)
        }
        return String(format: "%.2f Mbps", mbps)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var launchAtLogin: Bool = false

    init() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLogin = enabled
            } catch {
                print("Failed to set launch at login: \(error)")
            }
        }
    }
}
