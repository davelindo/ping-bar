import Foundation
import CoreWLAN

enum WiFiBand: String {
    case band2GHz = "2.4 GHz"
    case band5GHz = "5 GHz"
    case band6GHz = "6 GHz"
    case unknown = "Unknown"

    static func from(channel: CWChannel?) -> WiFiBand {
        guard let channel = channel else { return .unknown }
        switch channel.channelBand {
        case .band2GHz: return .band2GHz
        case .band5GHz: return .band5GHz
        case .band6GHz: return .band6GHz
        default: return .unknown
        }
    }
}

enum WiFiStandard: String {
    case legacy = "802.11a/b/g"
    case wifi4 = "Wi-Fi 4"
    case wifi5 = "Wi-Fi 5"
    case wifi6 = "Wi-Fi 6"
    case wifi6e = "Wi-Fi 6E"
    case wifi7 = "Wi-Fi 7"
    case unknown = "Unknown"

    var isLegacy: Bool {
        self == .legacy || self == .wifi4
    }

    static func from(phyMode: CWPHYMode?, band: WiFiBand) -> WiFiStandard {
        if let phyMode = phyMode, String(describing: phyMode).contains("11be") {
            return .wifi7
        }
        switch phyMode {
        case .some(.mode11b), .some(.mode11a), .some(.mode11g):
            return .legacy
        case .some(.mode11n):
            return .wifi4
        case .some(.mode11ac):
            return .wifi5
        case .some(.mode11ax):
            return band == .band6GHz ? .wifi6e : .wifi6
        default:
            return .unknown
        }
    }
}

struct WiFiInfo: Equatable {
    let ssid: String?
    let interfaceName: String?
    let rssi: Int
    let noise: Int
    let channel: Int
    let band: WiFiBand
    let linkRate: Double
    let standard: WiFiStandard

    var signalQuality: Int {
        let snr = rssi - noise
        return max(0, min(100, (snr + 10) * 2))
    }
}

struct WiFiIdentity: Equatable {
    let ssid: String?
    let interfaceName: String?
}

final class WiFiService {
    private let client = CWWiFiClient.shared()

    func getCurrentIdentity() -> WiFiIdentity? {
        guard let interface = client.interface() else { return nil }
        guard interface.powerOn() else { return nil }
        return WiFiIdentity(ssid: interface.ssid(), interfaceName: interface.interfaceName)
    }

    func getCurrentInfo() -> WiFiInfo? {
        guard let interface = client.interface() else { return nil }
        guard interface.powerOn() else { return nil }

        let channel = interface.wlanChannel()?.channelNumber ?? 0
        let band = WiFiBand.from(channel: interface.wlanChannel())
        let standard = WiFiStandard.from(phyMode: interface.activePHYMode(), band: band)

        return WiFiInfo(
            ssid: interface.ssid(),
            interfaceName: interface.interfaceName,
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            channel: channel,
            band: band,
            linkRate: interface.transmitRate(),
            standard: standard
        )
    }
}
