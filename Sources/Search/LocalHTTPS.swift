import Foundation

enum LocalHTTPS {
    static let faults: Set<LoadFault> = [.cannotConnect, .connectionLost, .cannotParse, .badResponse]

    static func counts(_ fault: LoadFault) -> Bool {
        faults.contains(fault)
    }

    static func candidate(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host(percentEncoded: false)?.lowercased(), Address.isLocal(host: host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url
    }

    static func answered(_ fault: LoadFault) -> Bool {
        fault.isCertificate
    }
}
