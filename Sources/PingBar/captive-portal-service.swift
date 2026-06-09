import Foundation
import AppKit

final class CaptivePortalService {
    private let testURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    func check(completion: @escaping @MainActor @Sendable (CaptivePortalStatus) -> Void) {
        var request = URLRequest(url: testURL)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let fallbackURL = testURL

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let status: CaptivePortalStatus
            if let error = error {
                status = .noInternet(error.localizedDescription)
            } else if let httpResponse = response as? HTTPURLResponse,
                      let data = data,
                      let body = String(data: data, encoding: .utf8) {
                if httpResponse.statusCode == 200 && body.contains("Success") {
                    status = .connected
                } else {
                    status = .captivePortal(httpResponse.url ?? fallbackURL)
                }
            } else {
                status = .noInternet("No response")
            }

            Task { @MainActor in
                completion(status)
            }
        }
        task.resume()
    }

    @MainActor
    func openLoginPage(url: URL) {
        NSWorkspace.shared.open(url)
    }
}

enum CaptivePortalStatus: Equatable, Sendable {
    case unknown
    case connected
    case captivePortal(URL)
    case noInternet(String)
}
