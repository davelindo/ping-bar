import Foundation

final class DNSService {
    private let hostname: String

    init(hostname: String = "cloudflare.com") {
        self.hostname = hostname
    }

    func lookup() -> Double? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?

        let start = CFAbsoluteTimeGetCurrent()
        let status = getaddrinfo(hostname, nil, &hints, &result)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if let result = result {
            freeaddrinfo(result)
        }

        return status == 0 ? elapsed : nil
    }

    func currentServers() -> [String] {
        guard let contents = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return []
        }
        return contents
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("nameserver") else { return nil }
                let parts = trimmed.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                return String(parts[1])
            }
    }
}
