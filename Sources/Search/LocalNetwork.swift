import Foundation
import Observation
import WebKit

enum LocalNetwork {
    enum Reach: Equatable {
        case loopback, lan, internet
    }

    enum Step: Equatable {
        case go, ask, stop
    }

    static let kind = "localnetwork"
    static let identifier = "broadway-local-network"
    static let settingKey = "localnetwork.ask"

    static let publicForTesting: Set<String> = {
        guard Store.testing else { return [] }
        let listed = ProcessInfo.processInfo.environment["SEARCH_PUBLIC_HOSTS"] ?? ""
        return Set(listed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }()

    static func reach(_ raw: String) -> Reach {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return .internet }
        if let parts = ipv4(host) { return reach(v4: parts) }
        if host.contains(":") { return reach(v6: host) }
        if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
        if [".local", ".test", ".internal", ".home.arpa"].contains(where: { host.hasSuffix($0) }) { return .lan }
        if !host.contains(".") { return .lan }
        return .internet
    }

    static func reach(_ url: URL?) -> Reach? {
        guard let url, ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? ""), let host = url.host(percentEncoded: false) else { return nil }
        return reach(host)
    }

    static func isLocal(_ url: URL?) -> Bool {
        guard let reach = reach(url) else { return false }
        if let host = url?.host(percentEncoded: false)?.lowercased(), publicForTesting.contains(host) { return false }
        return reach != .internet
    }

    static func isPublicPage(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if publicForTesting.contains(host) { return true }
        return reach(host) == .internet
    }

    static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let standard = (scheme == "http" && url.port == 80) || (scheme == "https" && url.port == 443)
        return "\(scheme)://\(shown)" + (url.port.flatMap { standard ? nil : ":\($0)" } ?? "")
    }

    static func origin(_ frame: WKSecurityOrigin) -> URL? {
        guard !frame.protocol.isEmpty, !frame.host.isEmpty else { return nil }
        let host = frame.host.contains(":") && !frame.host.hasPrefix("[") ? "[\(frame.host)]" : frame.host
        return URL(string: "\(frame.protocol)://\(host)" + (frame.port == 0 ? "" : ":\(frame.port)"))
    }

    static func key(_ origin: String) -> String { "capture.\(origin)|\(kind)" }

    static func shown(_ url: URL) -> String {
        guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
        let named = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return url.port.map { "\(named):\($0)" } ?? named
    }

    static func guards(page: URL?, on: Bool, answer: Bool?, developer: Bool) -> Bool {
        on && isPublicPage(page) && answer != true && !developer
    }

    static func step(source: URL?, target: URL?, userInitiated: Bool, redirect: Bool, type: WKNavigationType,
                     on: Bool, answer: Bool?, developer: Bool) -> Step {
        guard on, !userInitiated, !redirect, type != .backForward, type != .reload,
              isPublicPage(source), isLocal(target), !developer else { return .go }
        switch answer {
        case true?: return .go
        case false?: return .stop
        case nil: return .ask
        }
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }
        let numbers = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.count <= 3, piece.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(piece).flatMap { $0 <= 255 ? $0 : nil }
        }
        return numbers.count == 4 ? numbers : nil
    }

    private static func reach(v4 parts: [Int]) -> Reach {
        let (a, b) = (parts[0], parts[1])
        if a == 127 || a == 0 { return .loopback }
        if a == 10 { return .lan }
        if a == 172, (16...31).contains(b) { return .lan }
        if a == 192, b == 168 { return .lan }
        if a == 169, b == 254 { return .lan }
        if a == 100, (64...127).contains(b) { return .lan }
        return .internet
    }

    private static func reach(v6 host: String) -> Reach {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(AF_INET6, host, &bytes) == 1 else { return .internet }
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return .loopback }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return reach(v4: bytes[12..<16].map(Int.init))
        }
        if bytes[0] & 0xfe == 0xfc { return .lan }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .lan }
        return .internet
    }

    private static let start = "^[a-z]+://([^/@]*@)?"
    private static let end = "\\.?(:[0-9]+)?/"
    private static let number = "[0-9]+"

    static let hostPatterns: [String] = {
        let n = number
        let v4 = [
            "127\\.\(n)\\.\(n)\\.\(n)", "0\\.\(n)\\.\(n)\\.\(n)",
            "10\\.\(n)\\.\(n)\\.\(n)", "192\\.168\\.\(n)\\.\(n)", "169\\.254\\.\(n)\\.\(n)",
            "172\\.1[6-9]\\.\(n)\\.\(n)", "172\\.2[0-9]\\.\(n)\\.\(n)", "172\\.3[01]\\.\(n)\\.\(n)",
            "100\\.6[4-9]\\.\(n)\\.\(n)", "100\\.[7-9][0-9]\\.\(n)\\.\(n)",
            "100\\.1[01][0-9]\\.\(n)\\.\(n)", "100\\.12[0-7]\\.\(n)\\.\(n)",
        ]
        let v6 = [
            "\\[::1?\\]",
            "\\[::ffff:[0-9a-f][0-9a-f]?:[0-9a-f:]*\\]", "\\[::ffff:7f[0-9a-f][0-9a-f]:[0-9a-f:]*\\]",
            "\\[::ffff:a[0-9a-f][0-9a-f]:[0-9a-f:]*\\]", "\\[::ffff:ac1[0-9a-f]:[0-9a-f:]*\\]",
            "\\[::ffff:c0a8:[0-9a-f:]*\\]", "\\[::ffff:a9fe:[0-9a-f:]*\\]", "\\[::ffff:64[4-7][0-9a-f]:[0-9a-f:]*\\]",
            "\\[f[cd][0-9a-f][0-9a-f]:[0-9a-f:]*\\]", "\\[fe[89ab][0-9a-f]:[0-9a-f:]*\\]",
        ]
        let names = [
            "[^./@:\\[]+",
            "[^/@:]*\\.localhost", "[^/@:]*\\.local", "[^/@:]*\\.test", "[^/@:]*\\.internal", "[^/@:]*\\.home\\.arpa",
        ]
        return v4 + v6 + names
    }()

    static var filters: [String] { hostPatterns.map { start + $0 + end } }

    static var rules: [[String: Any]] {
        filters.map { filter in
            [
                "trigger": ["url-filter": filter, "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
    }

    static var encodedRules: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
@Observable
final class LocalNetworkGuard {
    static let shared = LocalNetworkGuard()

    @ObservationIgnored private(set) var list: WKContentRuleList?
    private(set) var trouble: String?
    @ObservationIgnored var enabled = true
    @ObservationIgnored var blocked: [String] = []

    private final class Seat {
        var page: URL?
        var tab: UUID?
        var shy = false
        var attached = false
    }

    private let seats = NSMapTable<WKUserContentController, Seat>.weakToStrongObjects()
    @ObservationIgnored private var shyAnswers: [UUID: [String: Bool]] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    func compile() {
        guard list == nil, let json = LocalNetwork.encodedRules else { return }
        guard let store = Shield.store else {
            trouble = "WebKit has nowhere to compile it"
            return
        }
        store.compileContentRuleList(forIdentifier: LocalNetwork.identifier, encodedContentRuleList: json) { [weak self] compiled, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let compiled else {
                    self.trouble = error?.localizedDescription ?? "Compiling the local network list failed"
                    return
                }
                self.list = compiled
                self.refitAll()
            }
        }
    }

    func answer(for origin: String, tab: UUID?, shy: Bool) -> Bool? {
        if shy { return tab.flatMap { shyAnswers[$0]?[origin] } }
        return Store.settings.object(forKey: LocalNetwork.key(origin)) as? Bool
    }

    func remember(_ allowed: Bool, origin: String, tab: UUID?, shy: Bool) {
        if shy {
            guard let tab else { return }
            shyAnswers[tab, default: [:]][origin] = allowed
        } else {
            Store.settings.set(allowed, forKey: LocalNetwork.key(origin))
            SiteNotifications.shared.changed()
        }
        refitAll()
    }

    func forget(_ origin: String, tab: UUID) {
        shyAnswers[tab]?[origin] = nil
        refitAll()
    }

    func forget(tab: UUID) {
        shyAnswers[tab] = nil
        asked = asked.filter { !$0.hasPrefix(tab.uuidString) }
    }

    func developer(_ page: URL?) -> Bool { Developer.shared.isOn(page) }

    func tune(_ controller: WKUserContentController, for page: URL?, tab: UUID, shy: Bool) {
        let seat = seats.object(forKey: controller) ?? Seat()
        seat.page = page
        seat.tab = tab
        seat.shy = shy
        seats.setObject(seat, forKey: controller)
        asked = asked.filter { !$0.hasPrefix(tab.uuidString) }
        fit(controller, seat)
    }

    func guardedOrigin(_ controller: WKUserContentController) -> String? {
        guard let seat = seats.object(forKey: controller), seat.attached else { return nil }
        return LocalNetwork.origin(seat.page)
    }

    func firstAsk(tab: UUID, origin: String) -> Bool {
        asked.insert("\(tab.uuidString)|\(origin)").inserted
    }

    func refitAll() {
        for case let controller as WKUserContentController in seats.keyEnumerator().allObjects {
            if let seat = seats.object(forKey: controller) { fit(controller, seat) }
        }
    }

    func isAttached(_ controller: WKUserContentController) -> Bool {
        seats.object(forKey: controller)?.attached == true
    }

    private func fit(_ controller: WKUserContentController, _ seat: Seat) {
        let origin = LocalNetwork.origin(seat.page)
        let answer = origin.flatMap { self.answer(for: $0, tab: seat.tab, shy: seat.shy) }
        let wanted = list != nil && LocalNetwork.guards(page: seat.page, on: enabled, answer: answer, developer: developer(seat.page))
        guard wanted != seat.attached, let list else { return }
        if wanted { controller.add(list) } else { controller.remove(list) }
        seat.attached = wanted
    }

    static var sites: [(origin: String, allowed: Bool)] {
        Store.settings.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix("capture."), key.hasSuffix("|\(LocalNetwork.kind)"), let allowed = value as? Bool else { return nil }
            return (String(key.dropFirst("capture.".count).dropLast(LocalNetwork.kind.count + 1)), allowed)
        }.sorted { $0.origin < $1.origin }
    }

    func forget(_ origin: String) {
        Store.settings.removeObject(forKey: LocalNetwork.key(origin))
        SiteNotifications.shared.changed()
        refitAll()
    }
}
