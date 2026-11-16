import AppKit
import Combine
import Foundation
import Observation

enum AgentMode: String, CaseIterable {
    case ask, auto, bypass

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .auto: return "Auto"
        case .bypass: return "Bypass"
        }
    }

    var detail: String {
        switch self {
        case .ask: return "Asks before tabs, your Mac, sign-in, send, pay, delete and upload"
        case .auto: return "Asks before your Mac, send, pay, delete and upload"
        case .bypass: return "Never asks, except for your Mac. Captchas and passkeys still stop for you."
        }
    }

    static func read(_ stored: String?, bypassConsent: Bool) -> AgentMode {
        guard let mode = stored.flatMap(AgentMode.init(rawValue:)) else { return .auto }
        return mode == .bypass && !bypassConsent ? .auto : mode
    }
}

enum AgentAct: String, CaseIterable {
    case tab, signIn, address, upload, send, delete, pay, mac

    var heavy: Bool { ![.tab, .signIn, .address].contains(self) }

    var rank: Int { AgentAct.allCases.firstIndex(of: self) ?? 0 }

    func question(on site: String?) -> String {
        let place = site ?? "this site"
        switch self {
        case .tab: return site == nil ? "Let the agent look around?" : "Let the agent use \(place)?"
        case .signIn: return "Sign in on \(place)?"
        case .address: return "Fill your details on \(place)?"
        case .upload: return "Upload a file to \(place)?"
        case .send: return "Send on \(place)?"
        case .delete: return "Delete on \(place)?"
        case .pay: return "Pay on \(place)?"
        case .mac: return "Let the agent use your Mac?"
        }
    }

    var yes: String {
        switch self {
        case .tab: return "Allow"
        case .signIn: return "Sign In"
        case .address: return "Fill"
        case .upload: return "Upload"
        case .send: return "Send"
        case .delete: return "Delete"
        case .pay: return "Pay"
        case .mac: return "Allow"
        }
    }
}

enum AgentStop: String {
    case captcha, passkey

    var title: String { self == .captcha ? "A captcha needs you" : "A passkey needs you" }
}

enum SiteRule: String, Codable {
    case always, never
}

enum AgentVerdict: Equatable {
    case go, ask, refuse
}

enum AgentPolicy {
    static func verdict(_ act: AgentAct, mode: AgentMode, rule: SiteRule?) -> AgentVerdict {
        if rule == .never { return .refuse }
        if act == .mac { return .ask }
        if mode == .bypass { return .go }
        if rule == .always { return act == .pay ? .ask : .go }
        if mode == .ask { return .ask }
        return act.heavy ? .ask : .go
    }

    static func allowsSiteRule(_ act: AgentAct, site: String?) -> Bool { site != nil && act != .mac }

    static func offersAlways(_ act: AgentAct) -> Bool { act != .pay && act != .mac }
}

struct ActionFacts: Equatable {
    var name = ""
    var optionLabel = ""
    var optionValue = ""
    var role = ""
    var tag = ""
    var type = ""
    var autocomplete = ""
    var href = ""
    var formAction = ""
    var formMethod = ""
    var formSearch = false
    var formPassword = false
    var formCard = false
    var fileField = false
    var captcha = false

    init(_ found: [String: Any] = [:]) {
        name = found["name"] as? String ?? ""
        optionLabel = found["optionLabel"] as? String ?? ""
        optionValue = found["optionValue"] as? String ?? ""
        role = found["role"] as? String ?? ""
        tag = found["tag"] as? String ?? ""
        type = found["type"] as? String ?? ""
        autocomplete = found["autocomplete"] as? String ?? ""
        href = found["href"] as? String ?? ""
        formAction = found["formAction"] as? String ?? ""
        formMethod = (found["formMethod"] as? String ?? "").lowercased()
        formSearch = found["formSearch"] as? Bool ?? false
        formPassword = found["formPassword"] as? Bool ?? false
        formCard = found["formCard"] as? Bool ?? false
        fileField = found["fileField"] as? Bool ?? false
        captcha = found["captcha"] as? Bool ?? false
    }
}

enum ActionKind: Equatable {
    case plain
    case act(AgentAct)
    case stop(AgentStop)

    private static func words(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(pattern))(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    private static let pay = words("pay|pay now|buy|buy now|purchase|checkout|check out|place (your )?order|order now|complete (your )?(order|purchase)|subscribe|upgrade|donate|tip|add funds|top up|book now|reserve|transfer|bezahlen|kaufen|acheter|payer|pagar|comprar|оплатить|купить|заказать")
    private static let delete = words("delete|remove|erase|destroy|wipe|discard|trash|bin|archive all|close (my |your )?account|deactivate|cancel (my |your )?(subscription|plan|order|account)|unsubscribe|revoke|clear all|löschen|supprimer|eliminar|borrar|удалить")
    private static let send = words("send|send now|submit|post|publish|reply|respond|comment|tweet|share|merge|deploy|release|confirm|approve|accept|sign|invite|apply|forward|save and send|senden|envoyer|enviar|absenden|отправить|опубликовать")
    private static let amount = try? NSRegularExpression(pattern: "(?:[$€£¥₽]\\s?\\d)|(?:\\d\\s?(?:usd|eur|gbp|rub)\\b)", options: [.caseInsensitive])
    private static let passkey = words("passkey|passkeys|security key|webauthn|face id|touch id|windows hello")

    private static func has(_ expression: NSRegularExpression?, _ text: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func plainWords(_ text: String) -> String {
        let hidden = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00AD}")
        let kept = text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !hidden.contains($0) }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func of(_ facts: ActionFacts, declared: AgentAct? = nil, enter: Bool = false) -> ActionKind {
        let names = [facts.name, facts.optionLabel, facts.optionValue].map(plainWords)
        func matches(_ expression: NSRegularExpression?) -> Bool { names.contains { has(expression, $0) } }
        if facts.captcha { return .stop(.captcha) }
        if facts.autocomplete.lowercased().contains("webauthn") || matches(passkey) { return .stop(.passkey) }
        var found: AgentAct?
        func note(_ act: AgentAct) { if act.rank > (found?.rank ?? -1) { found = act } }
        if facts.fileField { note(.upload) }
        if facts.formCard || matches(pay) || matches(amount) { note(.pay) }
        if matches(delete) { note(.delete) }
        if matches(send) { note(.send) }
        let submits = facts.type == "submit" || (facts.tag == "button" && facts.type.isEmpty) || enter
        let inForm = !facts.formAction.isEmpty || !facts.formMethod.isEmpty
        if submits, inForm, !facts.formSearch {
            if facts.formPassword { note(.signIn) } else if facts.formMethod == "post" { note(.send) }
        }
        if let declared { note(declared) }
        return found.map(ActionKind.act) ?? .plain
    }
}

@MainActor
@Observable
final class AgentSites {
    static let shared = AgentSites(file: Store.file("agent-sites.json"))

    private(set) var rules: [String: SiteRule] = [:]
    @ObservationIgnored private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([String: SiteRule].self, from: data) {
            rules = read
        }
    }

    static func site(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return Registrable.domain(of: host, isSuffix: AtRest.systemSuffix)
    }

    func rule(for site: String?) -> SiteRule? {
        site.flatMap { rules[$0] }
    }

    func set(_ rule: SiteRule?, for site: String) {
        rules[site] = rule
        let snapshot = rules
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }

    func reset() {
        for site in rules.keys { set(nil, for: site) }
    }
}

struct AgentQuestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case approval(AgentAct)
        case stop(AgentStop)
        case choice([String])
    }

    let id = UUID()
    let kind: Kind
    let title: String
    var task: UUID?
    var tab: Tab.ID?
    var site: String?
    var quote = ""
    var quoteLabel = "The page says"
    var reason = ""
    var shown = Date()

    var keyDelay: TimeInterval {
        switch kind {
        case .approval(let act): return act.heavy ? 0.5 : 1
        case .stop, .choice: return 0.5
        }
    }

    static func clean(_ text: String, limit: Int = 140) -> String {
        let bidi = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        let kept = text.unicodeScalars.filter { !bidi.contains($0) && !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
        let flat = String(String.UnicodeScalarView(kept)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

enum AgentAnswer: Equatable {
    case yes, no, always, never
    case picked(Int)
    case dropped
}

@MainActor
@Observable
final class AgentDesk {
    static let shared = AgentDesk()

    private(set) var pending: [AgentQuestion] = []
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<AgentAnswer, Never>] = [:]
    @ObservationIgnored private var granted: Set<String> = []
    @ObservationIgnored var told: ((AgentQuestion) -> Void)?

    var front: AgentQuestion? { pending.first }

    func waits(for task: UUID?) -> Bool {
        guard let task else { return false }
        return pending.contains { $0.task == task }
    }

    func ask(_ question: AgentQuestion) async -> AgentAnswer {
        await withCheckedContinuation { done in
            waiting[question.id] = done
            pending.append(question)
            told?(question)
        }
    }

    func take(_ id: UUID, _ answer: AgentAnswer) {
        guard let done = waiting.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        done.resume(returning: answer)
    }

    @discardableResult
    func press(_ answer: AgentAnswer, at now: Date = Date()) -> Bool {
        guard let question = front, now.timeIntervalSince(question.shown) >= question.keyDelay else { return false }
        take(question.id, answer)
        return true
    }

    func drop(task: UUID) {
        for question in pending where question.task == task { take(question.id, .dropped) }
        granted = granted.filter { !$0.hasPrefix(task.uuidString) }
    }

    private func key(_ act: AgentAct, _ task: UUID?, _ site: String?) -> String {
        "\(task?.uuidString ?? "anyone")|\(act.rawValue)|\(site ?? "")"
    }

    func isGranted(_ act: AgentAct, task: UUID?, site: String?) -> Bool {
        task != nil && granted.contains(key(act, task, site))
    }

    func grant(_ act: AgentAct, task: UUID?, site: String?) {
        if task != nil, !act.heavy { granted.insert(key(act, task, site)) }
    }
}

extension AgentDesk {
    func benchAsk(_ question: AgentQuestion) {
        pending.removeAll()
        pending.append(question)
    }
}

extension Browser {
    func deskKey(_ event: NSEvent) -> Bool {
        let desk = AgentDesk.shared
        guard let question = desk.front, !event.isARepeat else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 {
            if flags == .option, canRule(question) { return desk.press(.never) }
            return flags.isEmpty ? desk.press(.no) : false
        }
        switch question.kind {
        case .approval(let act):
            if act.heavy { return isReturn && flags == .command && desk.press(.yes) }
            guard isReturn, flags.isEmpty, !editing else { return false }
            return desk.press(.yes)
        case .stop:
            return isReturn && flags == .command && desk.press(.yes)
        case .choice(let options):
            guard flags.isEmpty, !editing,
                  let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...min(9, options.count)).contains(digit)
            else { return false }
            return desk.press(.picked(digit - 1))
        }
    }

    func canRule(_ question: AgentQuestion) -> Bool {
        guard case .approval(let act) = question.kind else { return false }
        return AgentPolicy.allowsSiteRule(act, site: question.site)
    }

    func showQuestionTab(_ question: AgentQuestion) {
        guard let id = question.tab, let tab = tabs.first(where: { $0.id == id }) else { return }
        select(tab)
    }
}

final class AgentCardView: NSView {
    let browser: Browser
    let desk: AgentDesk
    private let glass = KitGlass.floating(radius: 16)
    private let stage = KitFlippedView()
    private var shownID: UUID?
    private var shownCount = 0
    private var shownActive: Tab.ID?
    private var option = false
    private var flags: Any?
    private var face: NSView?
    private let title = KitLabel("", font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ink)
    private let who = KitLabel("", font: .systemFont(ofSize: 11, weight: .medium), color: KitColor.muted)
    private let count = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.faint)
    private let quote = AgentCardView.wrapping(lines: 2)
    private let reason = AgentCardView.wrapping(lines: 3)
    private var buttons: [NSView] = []
    private var choices: [AgentChoiceRow] = []

    static let widest: CGFloat = 460
    private static let pad: CGFloat = 14

    init(browser: Browser, desk: AgentDesk) {
        self.browser = browser
        self.desk = desk
        super.init(frame: NSRect(x: 0, y: 0, width: Self.widest, height: 100))
        glass.hold(stage)
        addSubview(glass)
        for view in [title, who, count, quote, reason] as [NSView] { stage.addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let flags { NSEvent.removeMonitor(flags) }
            flags = nil
        } else if flags == nil {
            flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = event.modifierFlags.contains(.option)
                    if now != self.option {
                        self.option = now
                        self.shownID = nil
                        self.needsLayout = true
                    }
                }
                return event
            }
        }
    }

    func sync() {
        if browser.activeID != shownActive {
            shownID = nil
            needsLayout = true
        }
    }

    private func rebuild(_ question: AgentQuestion) {
        shownID = question.id
        shownCount = desk.pending.count
        shownActive = browser.activeID
        face?.removeFromSuperview()
        let link = question.task.flatMap { AgentLinks.shared.link(AgentTasks.shared.root($0)) }
        let made = AgentCharacterFace(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        made.mood = .waving
        made.colour = link.map { AgentCharacter.accentColor($0.accent) } ?? KitColor.ink
        made.seed = link?.seed ?? 0
        stage.addSubview(made)
        face = made
        title.text = question.title
        who.text = link.map { $0.task ? "" : $0.name } ?? ""
        who.isHidden = who.text.isEmpty
        count.text = "1 of \(desk.pending.count)"
        count.isHidden = desk.pending.count <= 1
        quote.stringValue = question.quote.isEmpty ? "" : "\(question.quoteLabel): “\(question.quote)”"
        quote.isHidden = question.quote.isEmpty
        reason.stringValue = question.reason.isEmpty ? "" : "The agent says: \(question.reason)"
        reason.isHidden = question.reason.isEmpty
        for view in buttons { view.removeFromSuperview() }
        for row in choices { row.removeFromSuperview() }
        buttons = []
        choices = []
        let id = question.id
        func key(_ keys: String, _ word: String, _ answer: AgentAnswer) -> KitGlassKey {
            let made = KitGlassKey(title: word) { AgentDesk.shared.take(id, answer) }
            made.content = CommandHintView(keys, word, answers: true)
            made.setAccessibilityLabel(word)
            return made
        }
        var trailing: [NSView] = []
        switch question.kind {
        case .approval(let act):
            if AgentPolicy.allowsSiteRule(act, site: question.site), AgentPolicy.offersAlways(act) {
                trailing.append(KitGlassKey(title: "Always Here", quiet: true) { AgentDesk.shared.take(id, .always) })
            }
            let never = option && browser.canRule(question)
            trailing.append(key(never ? "⌥esc" : "esc", never ? "Never Here" : "Not Now", never ? .never : .no))
            trailing.append(key(act.heavy ? "⌘↩" : "↩", act.yes, .yes))
        case .stop:
            trailing.append(key("esc", "Not Now", .no))
            trailing.append(key("⌘↩", "Done", .yes))
        case .choice(let options):
            for (index, option) in options.prefix(9).enumerated() {
                let row = AgentChoiceRow(number: index + 1, text: AgentQuestion.clean(option, limit: 90)) {
                    AgentDesk.shared.take(id, .picked(index))
                }
                stage.addSubview(row)
                choices.append(row)
            }
            trailing.append(key("esc", "Not Now", .no))
        }
        var leading: [NSView] = []
        if question.tab != nil, question.tab != browser.activeID {
            let browser = browser
            leading.append(KitGlassKey(title: "Show Tab", quiet: true) { browser.showQuestionTab(question) })
        }
        buttons = leading + trailing
        leadingCount = leading.count
        for view in buttons { stage.addSubview(view) }
        setAccessibilityLabel(question.title)
    }

    private var leadingCount = 0

    static func wrapping(lines: Int) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = KitColor.muted
        field.maximumNumberOfLines = lines
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    private func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
    }

    private func contentHeight(width: CGFloat) -> CGFloat {
        let inner = width - Self.pad * 2
        var height = Self.pad + 18
        if !quote.isHidden { height += 8 + self.height(of: quote, width: inner + 4) }
        if !reason.isHidden { height += 8 + self.height(of: reason, width: inner + 4) }
        if !choices.isEmpty { height += 8 + CGFloat(choices.count) * (AgentChoiceRow.height + 4) }
        height += 8 + 22 + Self.pad
        return height
    }

    override var intrinsicContentSize: NSSize {
        if let question = desk.front, question.id != shownID { rebuild(question) }
        let width = bounds.width > 0 ? min(Self.widest, bounds.width) : Self.widest
        return NSSize(width: NSView.noIntrinsicMetric, height: desk.front == nil ? 0 : contentHeight(width: width))
    }

    override func layout() {
        super.layout()
        guard let question = desk.front else {
            isHidden = true
            return
        }
        isHidden = false
        if question.id != shownID || desk.pending.count != shownCount { rebuild(question); invalidateIntrinsicContentSize() }
        let width = min(Self.widest, bounds.width)
        let height = contentHeight(width: width)
        glass.frame = NSRect(x: 0, y: bounds.height - height, width: width, height: height)
        stage.frame = glass.bounds
        let inner = width - Self.pad * 2
        let scale = kitScale
        var y = Self.pad
        face?.frame = NSRect(x: Self.pad, y: y, width: 18, height: 18)
        var right = Self.pad + inner
        for label in [count, who] where !label.isHidden {
            let w = min(FieldLine.width(label, scale: scale), max(0, right - Self.pad - 26))
            right -= w
            label.frame = stage.kitSnap(NSRect(x: right, y: y, width: w, height: 18))
            right -= 8
        }
        let titleWidth = min(FieldLine.width(title, scale: scale), max(0, right - (Self.pad + 26)))
        title.frame = stage.kitSnap(NSRect(x: Self.pad + 26, y: y, width: titleWidth, height: 18))
        y += 18
        for label in [quote, reason] where !label.isHidden {
            y += 8
            let h = self.height(of: label, width: inner + 4)
            label.frame = NSRect(x: Self.pad - 2, y: y, width: inner + 4, height: h)
            y += h
        }
        if !choices.isEmpty {
            y += 8
            for row in choices {
                row.frame = NSRect(x: Self.pad, y: y, width: inner, height: AgentChoiceRow.height)
                y += AgentChoiceRow.height + 4
            }
            y -= 4
        }
        y += 8
        var x = Self.pad
        for view in buttons.prefix(leadingCount) {
            let w = view.intrinsicContentSize.width
            view.frame = stage.kitSnap(NSRect(x: x, y: y, width: w, height: 22))
            x += w + SurfaceLook.keyGap
        }
        var end = Self.pad + inner
        for view in buttons.dropFirst(leadingCount).reversed() {
            let w = view.intrinsicContentSize.width
            end -= w
            view.frame = stage.kitSnap(NSRect(x: end, y: y, width: w, height: 22))
            end -= SurfaceLook.keyGap
        }
    }
}

final class AgentChoiceRow: NSView {
    static let height: CGFloat = 17
    private let number: KitLabel
    private let cap = KitBox(fill: Palette.NS.keycap.withAlphaComponent(0.5), corners: .radius(4))
    private let text: KitLabel
    private let act: () -> Void

    init(number: Int, text: String, act: @escaping () -> Void) {
        self.number = KitLabel("\(number)", font: .systemFont(ofSize: 11), color: KitColor.muted)
        self.text = KitLabel(text, font: .systemFont(ofSize: 13), color: KitColor.ink)
        self.act = act
        super.init(frame: .zero)
        addSubview(cap)
        cap.addSubview(self.number)
        addSubview(self.text)
        kitAccess(label: text, role: .button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let scale = kitScale
        let w = FieldLine.width(number, scale: scale) + 10
        let h = ceil(number.measure(width: .greatestFiniteMagnitude).height) + 2
        cap.frame = kitSnap(NSRect(x: 0, y: (bounds.height - h) / 2, width: w, height: h))
        number.frame = NSRect(x: 5, y: 0, width: w - 10, height: h)
        text.frame = kitSnap(NSRect(x: w + 8, y: 0, width: max(0, bounds.width - w - 8), height: bounds.height))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
    }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }
}
