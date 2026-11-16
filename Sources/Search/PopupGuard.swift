import Foundation
import WebKit

struct PopupHit: Equatable {
    var fade = 1.0
    var hidden = false
    var over = ""
    var cover = 0.0
    var active = true
    var link: URL?
    var masked = false

    init(fade: Double = 1, hidden: Bool = false, over: String = "", cover: Double = 0, active: Bool = true, link: URL? = nil,
         masked: Bool = false) {
        self.fade = fade
        self.hidden = hidden
        self.over = over
        self.cover = cover
        self.active = active
        self.link = link
        self.masked = masked
    }

    init?(_ body: Any?) {
        guard let body = body as? [String: Any] else { return nil }
        fade = (body["fade"] as? NSNumber)?.doubleValue ?? 1
        hidden = (body["hidden"] as? NSNumber)?.boolValue ?? false
        over = body["over"] as? String ?? ""
        cover = (body["cover"] as? NSNumber)?.doubleValue ?? 0
        active = (body["active"] as? NSNumber)?.boolValue ?? true
        link = (body["link"] as? String).flatMap(URL.init(string:)).flatMap(BlockedPopups.openable)
        masked = (body["masked"] as? NSNumber)?.boolValue ?? false
    }

    var unseen: Bool {
        fade < 0.1 || hidden || ["media", "control"].contains(over)
            || (over == "content" && cover >= 0.5) || (over == "nothing" && cover >= 0.9)
    }
}

enum PopupRefusal: String {
    case unseen
    case inert
    case astray
    case wary
    case tabUnder = "tab-under"
}

struct PopupSpawn: Equatable {
    let serial: Int
    let at: TimeInterval
    let tab: UUID?
    let refused: Bool
    let sized: Bool
    var reason: PopupRefusal?
}

enum PopupGuard {
    static let strikesToWary = 2
    static let tabUnderWindow: TimeInterval = 2
    static let signInPatience: TimeInterval = 15

    static func seen(_ hits: [PopupHit]) -> Bool {
        !hits.isEmpty && !hits.contains(where: { $0.unseen && !$0.masked }) && hits.contains(where: \.active)
    }

    static func refusal(_ hits: [PopupHit], url: URL?, page: URL?, sized: Bool, wary: Bool) -> PopupRefusal? {
        let home = BlockedPopups.site(of: page)
        let away = BlockedPopups.site(of: url)
        if let away, away == home { return nil }
        let listed = SignInWindows.listed(url)
        if hits.contains(where: { $0.unseen && !($0.masked && listed && $0.over != "media") }) { return .unseen }
        if !hits.isEmpty, hits.allSatisfy({ !$0.active }) { return .inert }
        if sized || SignInWindows.looks(url) { return nil }
        if let away, let link = hits.compactMap(\.link).last,
           let linked = BlockedPopups.site(of: link), linked != away {
            return .astray
        }
        if wary { return .wary }
        return nil
    }

    static func tabUnder(_ spawn: PopupSpawn, navigation: WKNavigationType, to url: URL?, page: URL?) -> Bool {
        guard !spawn.sized else { return false }
        guard navigation == .other || (navigation == .linkActivated && !spawn.refused) else { return false }
        guard let away = BlockedPopups.site(of: url) else { return false }
        if spawn.refused, spawn.reason != .unseen, SignInWindows.listed(url) { return false }
        return away != BlockedPopups.site(of: page)
    }

    @MainActor static var strikes: [String: Int] = [:]

    @MainActor static func wary(_ page: URL?) -> Bool {
        guard let site = BlockedPopups.site(of: page) else { return false }
        return strikes[site, default: 0] >= strikesToWary
    }

    @MainActor static func strike(_ page: URL?, for refusal: PopupRefusal, to url: URL? = nil) {
        guard refusal != .wary, !SignInWindows.listed(url), let site = BlockedPopups.site(of: page) else { return }
        strikes[site, default: 0] += 1
    }

    @MainActor static func forgive(_ site: String) {
        strikes[site] = nil
    }
}
