# PingBar

Network diagnostics in your menu bar. Monitor latency, WiFi signal, and connection quality at a glance.

**[Download Latest Release](https://github.com/davelindo/ping-bar/releases/latest/download/PingBar.zip)**

<p align="center">
  <img src="assets/pingbar.png" alt="PingBar Screenshot" width="400">
</p>

## Features

- **Menu bar latency or throughput** - Live ping or up/down rates in the menu bar
- **Wi‑Fi details** - Network name, signal strength, noise floor, link rate, band, and Wi‑Fi standard
- **Router ping** - Latency to gateway with jitter, packet loss, and sparkline history
- **Internet probe** - TCP latency to 1.1.1.1 with jitter, packet loss, and sparkline history
- **Throughput graph** - Live up/down history and total transfer counters
- **Data usage history** - Daily and per-SSID usage totals with retention controls
- **DNS lookup** - Resolution time for cloudflare.com with sparkline history
- **Speed test** - Cloudflare-based download/upload with lag-under-load rating
- **Captive portal detection** - Alerts when network login is required

## Install

1. Download [PingBar.zip](https://github.com/davelindo/ping-bar/releases/latest/download/PingBar.zip)
2. Unzip and move `PingBar.app` to Applications
3. Open PingBar

### Build from source

```bash
git clone https://github.com/davelindo/ping-bar.git
cd ping-bar
./scripts/build-app.sh
```

To build with an installed Xcode beta:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/build-app.sh
```

## Color Coding

| Metric | Green | Orange | Red |
|--------|-------|--------|-----|
| Latency | <30ms | <100ms | ≥100ms |
| Signal | >-50 dBm | >-70 dBm | ≤-70 dBm |
| Loss | 0% | <5% | ≥5% |

## Requirements

- macOS 13+
- Xcode 26.5+ or Xcode 27 beta for local builds
- Location permission (optional, for WiFi network name)

## License

MIT
