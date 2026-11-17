import AppKit
import Combine
import FoundationModels
import Observation

enum CommandOutput: String, Codable, CaseIterable, Identifiable {
    case inPlace, beside, below, reply, copied

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inPlace: return "In place"
        case .beside: return "Beside the text"
        case .below: return "Below the page"
        case .reply: return "In a reply box"
        case .copied: return "Copied"
        }
    }
}

struct TextCommand: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var model: ModelChoice?
    var output: CommandOutput = .beside
    var kinds: Set<PickedText.Kind> = Set(PickedText.Kind.allCases)
    var sites: [String] = []
    var rewrites = false
    var mine = false

    func fits(_ picked: PickedText, host: String?) -> Bool {
        guard kinds.contains(picked.kind) else { return false }
        guard !sites.isEmpty else { return true }
        guard let host = host?.lowercased() else { return false }
        return sites.contains { site in
            let wanted = site.lowercased().trimmingCharacters(in: .whitespaces)
            return host == wanted || host.hasSuffix("." + wanted)
        }
    }

    func prompt(language: String) -> String {
        prompt.replacingOccurrences(of: "{selection}", with: "the selected text")
            .replacingOccurrences(of: "{page}", with: "the page")
            .replacingOccurrences(of: "{url}", with: "the page's address")
            .replacingOccurrences(of: "{language}", with: language)
    }

    var wantsPage: Bool { prompt.contains("{page}") }
    var wantsAddress: Bool { prompt.contains("{url}") || wantsPage }

    static let standard: [TextCommand] = [
        TextCommand(id: "improve", name: "Improve Writing", prompt: "Improve the writing of {selection}. Keep its meaning, voice and language. Give only the new text.", output: .inPlace, rewrites: true),
        TextCommand(id: "fix", name: "Fix Spelling and Grammar", prompt: "Fix the spelling and grammar of {selection} and change nothing else. Give only the corrected text.", output: .inPlace, rewrites: true),
        TextCommand(id: "translate", name: "Translate", prompt: "Translate {selection} into {language}. If it is already in {language}, translate it into English. Give only the translation.", output: .beside),
        TextCommand(id: "summarize", name: "Summarize", prompt: "Summarize {selection} in a sentence or two.", output: .beside),
        TextCommand(id: "explain", name: "Explain Simply", prompt: "Explain {selection} simply, as to someone new to the subject.", output: .beside),
    ]

    static let optional: [TextCommand] = [
        TextCommand(id: "shorter", name: "Make Shorter", prompt: "Make {selection} shorter and keep its meaning. Give only the new text.", output: .inPlace, rewrites: true),
        TextCommand(id: "formal", name: "Make More Formal", prompt: "Make {selection} more formal and keep its meaning. Give only the new text.", output: .inPlace, rewrites: true),
        TextCommand(id: "define", name: "Define", prompt: "Define {selection} in one or two sentences.", output: .beside),
        TextCommand(id: "code", name: "Explain Code", prompt: "Explain what the code in {selection} does.", output: .beside, kinds: [.code, .page, .box]),
        TextCommand(id: "bugs", name: "Find Bugs", prompt: "Find the bugs in the code in {selection}, most serious first.", output: .beside, kinds: [.code, .page, .box]),
    ]

    static let builtIn = standard + optional
    static let onDevice: Set<String> = ["improve", "fix", "translate", "summarize", "shorter", "formal"]
}

@MainActor
@Observable
final class CommandStore {
    static let shared = CommandStore()

    private(set) var mine: [TextCommand] = []
    private(set) var extras: Set<String> = []
    private let file: URL
    private let defaults: UserDefaults

    init(file: URL = Store.file("commands.json"), defaults: UserDefaults = Store.settings) {
        self.file = file
        self.defaults = defaults
        if let data = try? Data(contentsOf: file) {
            mine = (try? JSONDecoder().decode([TextCommand].self, from: data)) ?? []
        }
        extras = Set(defaults.stringArray(forKey: "ai.commands.on") ?? [])
    }

    var active: [TextCommand] {
        TextCommand.standard + TextCommand.optional.filter { extras.contains($0.id) } + mine
    }

    func toggle(_ id: String, on: Bool) {
        if on { extras.insert(id) } else { extras.remove(id) }
        defaults.set(extras.sorted(), forKey: "ai.commands.on")
    }

    func save(_ command: TextCommand) {
        var command = command
        command.mine = true
        if let index = mine.firstIndex(where: { $0.id == command.id }) { mine[index] = command } else { mine.append(command) }
        write()
    }

    func delete(_ id: String) {
        mine.removeAll { $0.id == id }
        write()
    }

    func command(_ id: String) -> TextCommand? {
        TextCommand.builtIn.first { $0.id == id } ?? mine.first { $0.id == id }
    }

    private func write() {
        let list = mine
        Disk.write(file) { try? JSONEncoder().encode(list) }
    }
}

final class MacModelProvider: Provider, @unchecked Sendable {
    let plan = Plan.thisMac

    func status() async -> PlanStatus {
        guard !CLIGuard.underTest || CLIGuard.realAllowed, SystemLanguageModel.default.isAvailable else { return PlanStatus() }
        return PlanStatus(path: "Apple Intelligence", connected: true, account: "Apple Intelligence")
    }

    func models() -> [PlanModel] { [PlanModel(id: "", name: "This Mac")] }

    func start(_ request: ProviderRequest) -> ProviderSession {
        guard !CLIGuard.underTest || CLIGuard.realAllowed else { return ClaudeProvider.failing(.refused("A test run never calls a real model")) }
        var feed: AsyncThrowingStream<ProviderEvent, Error>.Continuation!
        let events = AsyncThrowingStream<ProviderEvent, Error> { feed = $0 }
        let out = feed!
        let system = request.system, prompt = request.prompt
        let worker = Task.detached {
            do {
                let session = LanguageModelSession(instructions: system)
                var said = ""
                out.yield(.started(model: "This Mac"))
                for try await part in session.streamResponse(to: prompt) {
                    let text = part.content
                    if text.count > said.count, text.hasPrefix(said) { out.yield(.text(String(text.dropFirst(said.count)))) }
                    said = text
                }
                out.yield(.finished(ProviderUsage()))
                out.finish()
            } catch is CancellationError {
                out.finish(throwing: ProviderError.cancelled)
            } catch {
                out.finish(throwing: ProviderError.failed(error.localizedDescription))
            }
        }
        return ProviderSession(events: events, stopping: { worker.cancel() })
    }
}

enum TextDiff {
    struct Piece: Equatable {
        enum Kind { case same, added, removed }
        var kind: Kind
        var text: String
    }

    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            let space = character.isWhitespace
            if space != inSpace, !current.isEmpty {
                out.append(current)
                current = ""
            }
            inSpace = space
            current.append(character)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func pieces(from old: String, to new: String) -> [Piece] {
        let before = words(old), after = words(new)
        guard before.count * after.count < 4_000_000 else {
            return [Piece(kind: .removed, text: old), Piece(kind: .added, text: new)]
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: after.count + 1), count: before.count + 1)
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                table[i][j] = before[i] == after[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Piece] = []
        func add(_ kind: Piece.Kind, _ text: String) {
            if let last = out.last, last.kind == kind { out[out.count - 1].text += text } else { out.append(Piece(kind: kind, text: text)) }
        }
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, j < after.count, before[i] == after[j] {
                add(.same, before[i])
                i += 1
                j += 1
            } else if j < after.count, i == before.count || table[i][j + 1] >= table[i + 1][j] {
                add(.added, after[j])
                j += 1
            } else {
                add(.removed, before[i])
                i += 1
            }
        }
        return out
    }

    static func marked(from old: String, to new: String, font: NSFont, ink: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for piece in pieces(from: old, to: new) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            switch piece.kind {
            case .same: break
            case .added:
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = Palette.NS.safe
            case .removed:
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = Palette.NS.muted
            }
            out.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return out
    }
}

@MainActor
@Observable
final class CommandList {
    let picked: PickedText
    let tab: Tab
    let host: String?
    var typed = "" { didSet { index = 0 } }
    var index = 0

    init(picked: PickedText, tab: Tab) {
        self.picked = picked
        self.tab = tab
        host = tab.pageAddress?.host()
    }

    var rows: [TextCommand] {
        let wanted = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return CommandStore.shared.active.filter { command in
            command.fits(picked, host: host) && (wanted.isEmpty || command.name.lowercased().contains(wanted)) && runs(command)
        }
    }

    private func runs(_ command: TextCommand) -> Bool {
        !Plans.shared.looked || Plans.shared.commandChoice(command, blind: tab.neverSent, Shared.prefs) != nil
    }

    var asking: Bool { !typed.trimmingCharacters(in: .whitespaces).isEmpty }

    func keys(_ event: NSEvent, _ flags: NSEvent.ModifierFlags, _ browser: Browser) -> Bool {
        guard flags.isEmpty || flags == .numericPad || flags == .function || flags == [.numericPad, .function] else { return false }
        let count = rows.count + (asking ? 1 : 0)
        switch event.keyCode {
        case 125:
            index = min(index + 1, max(count - 1, 0))
            return true
        case 126:
            index = max(index - 1, 0)
            return true
        case 36, 76:
            take(browser)
            return true
        default:
            return false
        }
    }

    func take(_ browser: Browser) {
        let list = rows
        if index < list.count {
            browser.runCommand(list[index], picked: picked, tab: tab)
        } else if asking {
            browser.askOnSelection(typed, picked: picked, tab: tab)
        }
    }
}

@MainActor
@Observable
final class SelectionRun: Identifiable {
    let command: TextCommand
    let picked: PickedText
    let tab: Tab
    private(set) var text = ""
    private(set) var running = false
    private(set) var failed: String?
    private(set) var choice: ModelChoice
    var draft = ""
    var acting = false
    var showOriginal = false
    private var session: ProviderSession?
    private var past: [AIPrompt.Past] = []
    private var fence = AIPage.newFence()
    private var asked: String
    private var pageSource: AIPrompt.Source?

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(command: TextCommand, asked: String, picked: PickedText, tab: Tab, choice: ModelChoice) {
        self.command = command
        self.asked = asked
        self.picked = picked
        self.tab = tab
        self.choice = choice
    }

    var place: String { choice.plan == .thisMac ? "On this Mac" : "\(choice.plan.name) · \(choice.label)" }
    var showsDiff: Bool { command.rewrites && !running && failed == nil && !text.isEmpty }

    var request: ProviderRequest {
        var sources = [AIPrompt.Source(label: "The selected text", text: picked.text)]
        if command.wantsAddress, !tab.neverSent { sources.append(AIPrompt.Source(label: "The page's address", text: AIPage.shownAddress(tab.pageAddress))) }
        if let pageSource { sources.append(pageSource) }
        return ProviderRequest(system: AIPrompt.system(fence: fence, browsing: false),
                               prompt: AIPrompt.compose(fence: fence, sources: sources, history: past, request: asked))
    }

    func start() {
        session?.cancel()
        text = ""
        failed = nil
        running = true
        Task { @MainActor in
            if command.wantsPage, pageSource == nil, tab.canBeRead, let read = await AIPage.read(tab) {
                pageSource = AIPrompt.Source(read)
            }
            let live = Plans.shared.start(request, on: choice)
            session = live
            do {
                for try await event in live.events {
                    if case .text(let piece) = event { text += piece }
                }
            } catch ProviderError.cancelled {
            } catch {
                failed = error.localizedDescription
            }
            guard session === live else { return }
            running = false
            session = nil
            finished?()
        }
    }

    var finished: (() -> Void)?

    func stop() { session?.cancel() }

    var staysOnMac: Bool { tab.neverSent || choice.plan == .thisMac }

    func retry(on other: ModelChoice? = nil) {
        guard !running else { return }
        if let other {
            guard !staysOnMac || other.plan == .thisMac else { return }
            choice = other
        }
        start()
    }

    func followUp() {
        let wanted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !running else { return }
        past.append(AIPrompt.Past(mine: true, text: asked))
        past.append(AIPrompt.Past(mine: false, text: text))
        asked = wanted
        draft = ""
        start()
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func keys(_ event: NSEvent, _ flags: NSEvent.ModifierFlags, _ key: String, _ browser: Browser) -> Bool {
        if flags == .command, key == "c", !text.isEmpty {
            copy()
            browser.announce("Copied")
            browser.closeSelection()
            return true
        }
        if flags == .command, key == "r" {
            retry()
            return true
        }
        if flags == [.command, .shift], key == "r" {
            if !staysOnMac, let other = Plans.shared.otherChoice(than: choice, browser.prefs) { retry(on: other) }
            return true
        }
        if flags == .command, key == "k" {
            acting.toggle()
            return true
        }
        if flags.subtracting([.numericPad, .function]).isEmpty, event.keyCode == 36 || event.keyCode == 76,
           draft.trimmingCharacters(in: .whitespaces).isEmpty, !running, !text.isEmpty {
            browser.primary(self)
            return true
        }
        return false
    }
}

extension Browser {
    func openCommands(_ picked: PickedText, tab: Tab) {
        ai.result = nil
        ai.commands = CommandList(picked: picked, tab: tab)
    }

    func closeSelection() {
        ai.result?.stop()
        ai.result = nil
        ai.commands = nil
    }

    func choice(for command: TextCommand, tab: Tab) -> ModelChoice? {
        Plans.shared.commandChoice(command, blind: tab.neverSent, prefs)
    }

    func runCommand(_ command: TextCommand, picked: PickedText, tab: Tab, asked: String? = nil) {
        guard textActionsAllowed(on: tab) else { return closeSelection() }
        guard let choice = choice(for: command, tab: tab) else {
            ai.commands = nil
            return announce(textRefusal(tab))
        }
        let language = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
        let run = SelectionRun(command: command, asked: asked ?? command.prompt(language: language), picked: picked, tab: tab, choice: choice)
        ai.commands = nil
        ai.result = run
        run.finished = { [weak self, weak run] in
            guard let self, let run, run.failed == nil, !run.text.isEmpty else { return }
            if run.command.output == .copied {
                run.copy()
                self.announce("Copied")
                self.closeSelection()
            } else if run.command.output == .reply {
                Task { @MainActor in
                    if await PageSelection.putInBox(run.text, tab: run.tab) { self.closeSelection() }
                }
            }
        }
        run.start()
    }

    func askOnSelection(_ question: String, picked: PickedText, tab: Tab) {
        let command = TextCommand(id: "ask-\(UUID().uuidString)", name: Conversation.title(question),
                                  prompt: question + "\n\n{selection}", output: .beside, mine: true)
        runCommand(command, picked: picked, tab: tab, asked: "\(question)\n\nThis is about the selected text.")
    }

    func textCommand(_ id: String, in given: Tab? = nil) {
        guard let tab = given ?? active, textActionsAllowed(on: tab), let command = CommandStore.shared.command(id) else { return }
        Task { @MainActor in
            guard let picked = await PageSelection.read(tab) else { return announce("Select some text first") }
            if !Plans.shared.looked { await Plans.shared.refresh() }
            runCommand(command, picked: picked, tab: tab)
        }
    }

    func moreCommands(in given: Tab? = nil) {
        guard let tab = given ?? active, textActionsAllowed(on: tab) else { return }
        Task { @MainActor in
            guard let picked = await PageSelection.read(tab) else { return }
            if !Plans.shared.looked { await Plans.shared.refresh() }
            guard canRunAny(on: tab) else { return announce(textRefusal(tab)) }
            openCommands(picked, tab: tab)
        }
    }

    func primary(_ run: SelectionRun) {
        Task { @MainActor in
            if run.picked.editable {
                let put = await PageSelection.replace(run.text, tab: run.tab)
                announce(put ? "Replaced" : "The text has moved on the page")
            } else if run.command.output == .reply, await PageSelection.putInBox(run.text, tab: run.tab) {
                announce("Put in the page")
            } else {
                run.copy()
                announce("Copied")
            }
            closeSelection()
        }
    }

    func saveAsCommand(_ run: SelectionRun) {
        var command = run.command
        command.id = UUID().uuidString
        command.model = run.choice.plan == .thisMac ? nil : run.choice
        CommandStore.shared.save(command)
        announce("Saved as a command")
        run.acting = false
    }
}

extension SelectionRun {
    func benchFill(_ text: String) { self.text = text }
}

final class CommandHintView: NSView {
    var key: String { didSet { if key != oldValue { refresh() } } }
    var title: String { didSet { if title != oldValue { refresh() } } }
    let word: KitLabel
    private let cap = KitBox(fill: Palette.NS.keycap.withAlphaComponent(0.5), corners: .radius(4))
    private let keyLabel = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)

    init(_ key: String, _ title: String, answers: Bool = false) {
        self.key = key
        self.title = title
        word = KitLabel("", font: .systemFont(ofSize: answers ? BroadwaySize.small.font : 11), color: answers ? KitColor.ink : KitColor.muted)
        super.init(frame: .zero)
        for label in [word, keyLabel] { label.setAccessibilityElement(false) }
        addSubview(word)
        addSubview(cap)
        cap.addSubview(keyLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        word.text = title
        keyLabel.text = key
        setAccessibilityLabel("\(title) \(key)")
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let scale = kitScale
        let height = ceil(keyLabel.measure(width: .greatestFiniteMagnitude).height * scale) / scale + 2
        return NSSize(width: FieldLine.width(word, scale: scale) + 4 + FieldLine.width(keyLabel, scale: scale) + 8, height: height)
    }

    override func layout() {
        super.layout()
        let scale = kitScale
        let wordWidth = FieldLine.width(word, scale: scale)
        word.frame = kitSnap(NSRect(x: 0, y: 0, width: wordWidth, height: bounds.height))
        let capWidth = FieldLine.width(keyLabel, scale: scale) + 8
        cap.frame = kitSnap(NSRect(x: wordWidth + 4, y: 0, width: capWidth, height: bounds.height))
        keyLabel.frame = NSRect(x: 4, y: 0, width: capWidth - 8, height: bounds.height)
    }
}

final class SelectionOverlayView: NSView {
    let browser: Browser
    private var commands: CommandListPanel?
    private var result: SelectionResultPanel?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func sync() {
        let list = browser.ai.commands
        if commands?.list !== list {
            let old = commands
            commands = list.map { CommandListPanel(browser: browser, list: $0) }
            if let made = commands { addSubview(made) }
            if window != nil, old != nil { layer?.kitTransition(Motion.kitQuick) }
            old?.removeFromSuperview()
        }
        let run = browser.ai.result
        if result?.run !== run {
            result?.removeFromSuperview()
            result = run.map { SelectionResultPanel(browser: browser, run: $0) }
            if let made = result { addSubview(made) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let room = bounds
        let origin = window?.contentView.map { root -> CGPoint in
            let point = convert(NSPoint.zero, to: root)
            return root.isFlipped ? point : CGPoint(x: point.x, y: root.bounds.height - point.y)
        } ?? .zero
        let frame = CGRect(origin: origin, size: room.size)
        if let commands {
            let size = commands.fittingSize
            let spot = place(commands.list.picked.box, width: 300, frame: frame, beside: false)
            commands.frame = NSRect(x: spot.width, y: spot.height, width: 300, height: size.height)
        }
        if let result {
            if result.run.command.output == .below {
                let width = min(640, room.width - 28)
                let height = result.height(for: width)
                result.frame = NSRect(x: (room.width - width) / 2, y: room.height - 14 - height, width: width, height: height)
            } else {
                let height = result.height(for: 400)
                let spot = place(result.run.picked.box, width: 400, frame: frame, beside: result.run.command.output == .beside)
                result.frame = NSRect(x: spot.width, y: spot.height, width: 400, height: height)
            }
        }
    }

    private func place(_ box: CGRect, width: CGFloat, frame: CGRect, beside: Bool) -> CGSize {
        var x = (beside ? box.maxX + 10 : box.minX) - frame.minX
        var y = (beside ? box.minY : box.maxY + 6) - frame.minY
        if x + width > frame.width - 12 { x = frame.width - width - 12 }
        if y + 200 > frame.height { y = max(12, box.minY - frame.minY - 210) }
        x = max(12, x)
        y = max(12, y)
        return CGSize(width: x, height: y)
    }
}

final class SelectionField: NSTextField {
    var onFocus: (() -> Void)?

    static func make(placeholder: String, size: CGFloat) -> SelectionField {
        let field = SelectionField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: Palette.NS.faint,
        ])
        return field
    }

    func focus() {
        guard let window, window.firstResponder !== currentEditor() else { return }
        window.makeFirstResponder(self)
    }
}

final class CommandListPanel: NSView, NSTextFieldDelegate {
    let browser: Browser
    let list: CommandList
    private let glass = KitGlass.floating(radius: 12)
    private let stage = KitFlippedView()
    private let field = SelectionField.make(placeholder: "Ask about this, or pick a command", size: 13)
    private let rule = KitBox(fill: KitColor.hairline)
    private var rows: [CommandRow] = []
    private weak var before: NSResponder?

    private static let fieldHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 27

    init(browser: Browser, list: CommandList) {
        self.browser = browser
        self.list = list
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        glass.hold(stage)
        addSubview(glass)
        stage.addSubview(field)
        stage.addSubview(rule)
        field.delegate = self
        field.stringValue = list.typed
        field.kitAccess(id: "selection.commands.field", label: "Ask about this, or pick a command")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        before = window.firstResponder
        DispatchQueue.main.async { [weak self] in self?.field.focus() }
    }

    override func removeFromSuperview() {
        if let window, let editor = field.currentEditor(), window.firstResponder === editor {
            let back = before.flatMap { ($0 as? NSView)?.window === window ? $0 : nil }
            window.makeFirstResponder(back)
        }
        super.removeFromSuperview()
    }

    func controlTextDidChange(_ notification: Notification) {
        list.typed = field.stringValue
    }

    private var entries: [(title: String, detail: String)] {
        var out = list.rows.map { ($0.name, place($0)) }
        if list.asking {
            out.append(("Ask: \(list.typed)", browser.choice(for: TextCommand.standard[3], tab: list.tab).map(where_) ?? ""))
        }
        return out
    }

    private func place(_ command: TextCommand) -> String {
        browser.choice(for: command, tab: list.tab).map(where_) ?? "Not in a private window"
    }

    private func where_(_ choice: ModelChoice) -> String {
        choice.plan == .thisMac ? "This Mac" : "\(choice.plan.name), leaves this Mac"
    }

    override var fittingSize: NSSize {
        let count = CGFloat(entries.count)
        return NSSize(width: 300, height: 6 + Self.fieldHeight + 2 + 1 + count * (Self.rowHeight + 2) + 6)
    }

    override func layout() {
        super.layout()
        let shown = entries
        while rows.count > shown.count { rows.removeLast().removeFromSuperview() }
        for (index, entry) in shown.enumerated() {
            let row: CommandRow
            if index < rows.count { row = rows[index] } else {
                row = CommandRow()
                stage.addSubview(row)
                rows.append(row)
            }
            row.set(entry.title, entry.detail, picked: index == list.index)
            row.onPress = { [weak self] in
                guard let self else { return }
                self.list.index = index
                self.list.take(self.browser)
            }
        }
        if field.stringValue != list.typed { field.stringValue = list.typed }
        glass.frame = bounds
        stage.frame = glass.bounds
        let width = bounds.width - 12
        var y: CGFloat = 6
        let line = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 6 + 10 - 2, y: y + (Self.fieldHeight - line) / 2, width: width - 16, height: line)
        y += Self.fieldHeight + 2
        rule.frame = NSRect(x: 6, y: y, width: width, height: 1)
        y += 1 + 2
        for row in rows {
            row.frame = NSRect(x: 6, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight + 2
        }
    }
}

final class CommandRow: NSView {
    var onPress: (() -> Void)?
    private let ground = KitBox(fill: nil, corners: .radius(8))
    private let title = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.ink)
    private let detail = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.faint)

    init() {
        super.init(frame: .zero)
        for view in [ground, title, detail] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(_ title: String, _ detail: String, picked: Bool) {
        self.title.text = title
        self.detail.text = detail
        ground.fill = picked ? Palette.NS.fieldPick.withAlphaComponent(0.7) : nil
        setAccessibilityLabel(title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        FieldLine.place([.text(title), .spacer(8), .text(detail, fixed: true)], in: self, padding: 10, spacing: 8)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

final class SelectionResultPanel: NSView, NSTextFieldDelegate {
    let browser: Browser
    let run: SelectionRun
    private let glass = KitGlass.floating(radius: 12)
    private let stage = KitFlippedView()
    private let scroll = NSScrollView()
    private let words = NSTextView()
    private let save: KitGlassKey
    private let draft = SelectionField.make(placeholder: "Follow up", size: 12.5)
    private let place = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.faint)
    private var hints: [CommandHintView] = []
    private var flags: Any?
    private weak var before: NSResponder?

    private static let pad: CGFloat = 12
    private static let most: CGFloat = 260

    init(browser: Browser, run: SelectionRun) {
        self.browser = browser
        self.run = run
        save = KitGlassKey(title: "Save as Command") { browser.saveAsCommand(run) }
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        glass.hold(stage)
        addSubview(glass)
        words.isEditable = false
        words.isSelectable = true
        words.drawsBackground = false
        words.textContainerInset = .zero
        words.textContainer?.lineFragmentPadding = 0
        words.textContainer?.widthTracksTextView = true
        words.isVerticallyResizable = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = words
        draft.delegate = self
        draft.target = self
        draft.action = #selector(submit)
        draft.kitAccess(id: "selection.result.draft", label: "Follow up")
        for view in [scroll, save, draft, place] as [NSView] { stage.addSubview(view) }
        flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.run.showOriginal = event.modifierFlags.contains(.option) && self.run.command.rewrites
            }
            return event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        before = window.firstResponder
        DispatchQueue.main.async { [weak self] in self?.draft.focus() }
    }

    override func removeFromSuperview() {
        if let window, let editor = draft.currentEditor(), window.firstResponder === editor {
            let back = before.flatMap { ($0 as? NSView)?.window === window ? $0 : nil }
            window.makeFirstResponder(back)
        }
        if let flags {
            NSEvent.removeMonitor(flags)
            self.flags = nil
        }
        super.removeFromSuperview()
    }

    @objc private func submit() { run.followUp() }

    func controlTextDidChange(_ notification: Notification) {
        run.draft = draft.stringValue
    }

    private var pageFont: NSFont {
        let family = run.picked.family.split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
        let size = max(11, run.picked.size)
        guard !family.isEmpty else { return .systemFont(ofSize: 13) }
        return NSFont(name: family, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }

    private var font: NSFont { run.command.output == .inPlace ? pageFont : .systemFont(ofSize: 13) }

    private func text(dark: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ink = KitColor.ink.kitResolved(dark: dark)
        func plain(_ string: String, _ font: NSFont, _ color: NSColor) {
            out.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color.kitResolved(dark: dark)]))
        }
        if run.showOriginal {
            plain(run.picked.text, font, KitColor.muted)
        } else if run.showsDiff {
            out.append(TextDiff.marked(from: run.picked.text, to: run.text, font: font, ink: ink))
        } else if run.text.isEmpty, run.running {
            plain("…", .systemFont(ofSize: 13), KitColor.faint)
        } else {
            plain(run.text, font, KitColor.ink)
        }
        if let failed = run.failed {
            let gap = NSMutableParagraphStyle()
            gap.paragraphSpacingBefore = 6
            out.append(NSAttributedString(string: (out.length > 0 ? "\n" : "") + failed,
                                          attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: KitColor.muted.kitResolved(dark: dark),
                                                       .paragraphStyle: gap]))
        }
        return out
    }

    private func textHeight(for width: CGFloat) -> CGFloat {
        let string = text(dark: kitDark)
        let rect = string.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(Self.most, ceil(rect.height))
    }

    private var hintWords: [(String, String)] {
        if run.running { return [("esc", "Stop")] }
        return [("↩", run.picked.editable ? "Replace" : run.command.output == .reply ? "Insert" : "Copy"), ("⌘R", "Retry"), ("⌘K", "More")]
    }

    func height(for width: CGFloat) -> CGFloat {
        let inner = width - Self.pad * 2
        var height = Self.pad + textHeight(for: inner) + 8
        if run.acting { height += 22 + 8 }
        height += ceil(draft.intrinsicContentSize.height) + 8
        height += 15 + Self.pad
        return height
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        stage.frame = glass.bounds
        let inner = bounds.width - Self.pad * 2
        let string = text(dark: kitDark)
        words.textStorage?.setAttributedString(string)
        let textHeight = self.textHeight(for: inner)
        scroll.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: textHeight)
        words.frame = NSRect(x: 0, y: 0, width: inner, height: max(textHeight, words.frame.height))
        words.sizeToFit()
        var y = Self.pad + textHeight + 8
        save.isHidden = !run.acting
        if run.acting {
            let size = save.intrinsicContentSize
            save.frame = NSRect(x: Self.pad, y: y, width: size.width, height: 22)
            y += 22 + 8
        }
        if draft.stringValue != run.draft { draft.stringValue = run.draft }
        let line = ceil(draft.intrinsicContentSize.height)
        draft.frame = NSRect(x: Self.pad - 2, y: y, width: inner + 4, height: line)
        y += line + 8
        let wanted = hintWords
        if hints.map({ [$0.key, $0.title] }) != wanted.map({ [$0.0, $0.1] }) {
            for hint in hints { hint.removeFromSuperview() }
            hints = wanted.map { CommandHintView($0.0, $0.1) }
            for hint in hints { stage.addSubview(hint) }
        }
        place.text = run.place
        var x = bounds.width - Self.pad
        for hint in hints.reversed() {
            let size = hint.intrinsicContentSize
            x -= size.width
            hint.frame = kitSnap(NSRect(x: x, y: y + (15 - size.height) / 2, width: size.width, height: size.height))
            x -= 10
        }
        place.frame = NSRect(x: Self.pad, y: y, width: max(0, x - 6 + 10 - Self.pad), height: 15)
    }
}
