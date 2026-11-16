import AppKit
import Observation
import Foundation
import WebKit

struct OneTimeCode: Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    let code: String
    let sender: String
    let at: Date

    var id: String { "\(at.timeIntervalSince1970)\(code)" }
    var description: String { "code from gmail, \(code.count) characters" }
    var debugDescription: String { description }

    var detail: String { sender.isEmpty ? "Gmail" : "Gmail · \(sender)" }
}

enum CodeFinder {
    private static let keyword = regex(#"(?i)\b(?:codes?|otp|passcode|password|pin|verification|verify|confirm(?:ation)?|sign[ -]?in|log[ -]?in|login|authenticat\w*|2fa|mfa)\b|c[oó]digo|验证码|認証コード|인증"#)
    private static let strong = regex(#"(?i)verification|verify|\botp\b|one[ -]time|passcode|authenticat|2fa|\bmfa\b|sign[ -]?in|log[ -]?in"#)
    private static let selling = regex(#"(?i)\b(?:% off|off your|sale|discount|promo|coupon|voucher|unsubscribe|deal)\b"#)
    private static let candidate = regex(#"(?<![\w$€£.,/:#-])(?:G-)?(\d{3}[ -]\d{3}|\d{4,8}|(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{5,8})(?![\w%/:-]|[.,]\d)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch { fatalError("bad pattern") }
    }

    private static func has(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func code(in text: String) -> String? {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let keywords = keyword.matches(in: text, range: whole).map(\.range)
        guard !keywords.isEmpty else { return nil }
        if has(selling, text), !has(strong, text) { return nil }
        var best: (code: String, score: Int)?
        for match in candidate.matches(in: text, range: whole) {
            let range = match.range(at: 1)
            let raw = (text as NSString).substring(with: range)
            let before = keywords.filter { $0.upperBound <= match.range.lowerBound }.map { match.range.lowerBound - $0.upperBound }.min()
            let after = keywords.filter { $0.lowerBound >= match.range.upperBound }.map { $0.lowerBound - match.range.upperBound }.min()
            let digits = raw.filter(\.isNumber)
            if raw.contains(where: \.isLetter), (before ?? .max) > 12 { continue }
            if digits.count == 4, raw.count == 4, ["19", "20"].contains(String(raw.prefix(2))), (before ?? .max) > 12 { continue }
            let score = min(before ?? .max, (after ?? (.max - 40)) + 40)
            if score < (best?.score ?? .max) { best = (raw.filter { $0 != " " && $0 != "-" }, score) }
        }
        return best?.code
    }
}

enum CodeRead: Equatable {
    case found([OneTimeCode])
    case nothing
    case quiet
}

protocol CodeSource: AnyObject {
    func read(since: Date) async -> CodeRead
}

@MainActor
@Observable
final class CodeWatch {
    static let window: TimeInterval = 600
    static let every: TimeInterval = 5
    static let tries = 18

    @ObservationIgnored weak var browser: Browser?
    private let book: AutofillBook
    @ObservationIgnored var sources: (Tab) -> [CodeSource]
    @ObservationIgnored var pause: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    @ObservationIgnored var mayRead: (Tab) -> Bool = { tab in
        Store.testing || (NSApp.isActive && tab.built?.window?.isKeyWindow == true)
    }

    @ObservationIgnored private var watching: (tab: Tab.ID, task: Task<Void, Never>)?
    @ObservationIgnored private(set) var offered: [OneTimeCode] = []
    @ObservationIgnored private(set) var reads = 0

    init(book: AutofillBook = .shared) {
        self.book = book
        sources = { _ in [] }
        sources = { [weak self] _ in AutofillBook.rehearsing ? [] : self?.live() ?? [] }
    }

    private func live() -> [CodeSource] {
        var found: [CodeSource] = []
        if book.codesFromGmail, let browser,
           let address = GmailAccount.feed(account: GmailAccount.index(among: browser.tabs.filter { !$0.shy }.map(\.pageAddress))) {
            let store = Spaces.store(for: browser.spaceID)
            found.append(GmailCodes(
                feed: WebGmailFeed(address: address, store: store),
                signedIn: { await GmailAccount.signedIn(store) },
                told: { [weak browser] in browser?.announce("Looking in your Gmail for a code") }))
        }
        return found
    }

    func offers(on tab: Tab) -> [OneTimeCode] { watching?.tab == tab.id ? offered : [] }

    static func allowed(on page: URL?, privateTab: Bool) -> Bool {
        page?.scheme?.lowercased() == "https" && !privateTab
    }

    func focused(on tab: Tab, field: FormField?) {
        guard let field, FormClassifier.isCode(field), tab.fieldFrameHost == nil,
              Self.allowed(on: tab.pageAddress, privateTab: tab.shy)
        else {
            return stop()
        }
        if watching?.tab == tab.id { return }
        stop()
        let task = Task<Void, Never> { [weak self] in await self?.watch(tab) }
        watching = (tab.id, task)
    }

    func left(_ tab: Tab) {
        if watching?.tab == tab.id { stop() }
    }

    func stop() {
        guard let up = watching else { return }
        watching = nil
        offered = []
        up.task.cancel()
        if let tab = browser?.tabs.first(where: { $0.id == up.tab }) { tab.formPage?.holdEnter(false) }
    }

    private func watch(_ tab: Tab) async {
        let id = tab.id
        let sources = sources(tab)
        for attempt in 0..<Self.tries {
            guard !Task.isCancelled, watching?.tab == id || attempt == 0, browser?.active?.id == id, mayRead(tab) else { return }
            await lookOnce(tab, in: sources)
            guard !Task.isCancelled, offered.isEmpty else { return }
            await pause(Self.every)
        }
    }

    private func lookOnce(_ tab: Tab, in sources: [CodeSource]) async {
        reads += 1
        var found: [OneTimeCode] = []
        let since = Date().addingTimeInterval(-Self.window)
        for source in sources {
            guard !Task.isCancelled else { return }
            switch await source.read(since: since) {
            case .found(let codes): found += codes
            case .nothing, .quiet: break
            }
        }
        guard !Task.isCancelled else { return }
        found.sort { $0.at > $1.at }
        offered = Array(found.prefix(3))
        guard !offered.isEmpty else { return }
        tab.formPage?.holdEnter(true)
        browser?.offerCodes(offered, on: tab)
    }

    func use(_ code: OneTimeCode, in tab: Tab) {
        let origin = tab.pageAddress.map { "\($0.scheme ?? "https")://\($0.host() ?? "")" + ($0.port.map { ":\($0)" } ?? "") } ?? ""
        guard Self.allowed(on: tab.pageAddress, privateTab: tab.shy), let page = tab.formPage else { return }
        stop()
        Task {
            if await !page.put(code: code.code, origin: origin) {
                browser?.announce("Couldn't find the code box anymore")
            }
        }
    }
}
