import AppKit
import Observation

struct OnboardingScore: Equatable {
    var dimTakes: Double
    var grid: Double
    var gridTakes: Double
    var line: Double
    var lineTakes: Double
    var recede: Double
    var recedeTakes: Double
    var word: Double
    var letterTakes: Double
    var letterGap: Double
    var ends: Double
    var settleTakes: Double
    var drawn: Bool

    static let drawn = OnboardingScore(dimTakes: 1.2, grid: 0.2, gridTakes: 1.5, line: 1.1, lineTakes: 1.75,
                                       recede: 3.1, recedeTakes: 1.15, word: 3.55, letterTakes: 0.75, letterGap: 0.065,
                                       ends: 5.2, settleTakes: 0.75, drawn: true)
    static let calm = OnboardingScore(dimTakes: 0.4, grid: 0, gridTakes: 0, line: 0, lineTakes: 0,
                                      recede: 0, recedeTakes: 0, word: 0.15, letterTakes: 0.5, letterGap: 0,
                                      ends: 1.7, settleTakes: 0.35, drawn: false)

    static func current(reduced: Bool) -> OnboardingScore { reduced ? calm : drawn }

    var inkAt: Double { letterTakes * 0.55 }
    var inkLags: Double { letterTakes * 0.05 }
    var inkTakes: Double { letterTakes * 0.58 }
    var mapRests: Double { recede + recedeTakes }

    func written(letters: Int) -> Double {
        word + Double(max(letters - 1, 0)) * letterGap + max(letterTakes, inkAt + inkLags + inkTakes)
    }
}

@MainActor
protocol OnboardingStage: AnyObject {
    func raise(_ onboarding: Onboarding)
    func handOff(_ onboarding: Onboarding, done: @escaping () -> Void)
    func clear()
    func makeWay()
    func takeBack()
}

@MainActor
@Observable
final class Onboarding {
    static let shared = Onboarding()

    enum Phase: Equatable { case away, intro, steps, leaving }

    enum Step: String, CaseIterable {
        case space, side, links, agents, key, bring
    }

    nonisolated static let seenKey = "onboarding.seen"
    nonisolated static let showKey = "onboarding.show"
    nonisolated static let begunKey = "onboarding.begun"
    nonisolated static let profileFiles = ["session.json", "spaces.json", "history.json", "bookmarks.json", "pins.json"]
    nonisolated static let passing: Set<String> = ["q", "h", "m", "`", "a", "c", "v", "x", "z"]

    private(set) var phase: Phase = .away
    private(set) var steps: [Step] = Step.allCases
    private(set) var step: Step = .space
    private(set) var defaultAsked = false
    private(set) var bringing: String?
    private(set) var score = OnboardingScore.drawn
    private(set) var runs = 0
    var name = ""
    var look = "gray"
    var side = SidebarPosition.left
    var source = ""
    var keyTyped = "" { didSet { if keyTyped != oldValue, keyNote != nil, keys.state != .checking { keyNote = nil } } }
    var keyNote: String?
    private(set) var opened: [URL] = []

    @ObservationIgnored private let settings: UserDefaults
    @ObservationIgnored private(set) weak var browser: Browser?
    @ObservationIgnored weak var stage: OnboardingStage?
    @ObservationIgnored var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    @ObservationIgnored var isDefault: () -> Bool = { Store.testing ? false : Links.isDefault }
    @ObservationIgnored var askDefault: (@escaping () -> Void) -> Void = { answered in
        guard !Store.testing else {
            answered()
            return
        }
        Links.becomeDefault { _ in answered() }
    }
    @ObservationIgnored var sources: () -> [String] = {
        ImportSource.offered(found: ImportSource.installed().map(\.name), safari: ImportSource.safari)
    }
    @ObservationIgnored var defaultBrowser: () -> String? = { Store.testing ? nil : ImportSource.defaultBrowserName() }
    @ObservationIgnored private var arrived = false
    @ObservationIgnored var keys: OpenRouterKey = .shared
    @ObservationIgnored var keyLine: () -> String = {
        AIGroupWords.stepLine(mac: AIGroups.shared.available(.thisMac), remoteDecides: AIGroups.shared.remoteDecides)
    }
    @ObservationIgnored var openLink: (URL) -> Void = { url in
        guard !Store.testing else { return }
        NSWorkspace.shared.open(url)
    }

    init(settings: UserDefaults = Store.settings) {
        self.settings = settings
    }

    nonisolated static func due(testing: Bool, forced: Bool, seen: Bool, freshProfile: Bool, begun: Bool = false) -> Bool {
        if testing { return forced }
        return forced || (!seen && (freshProfile || begun))
    }

    nonisolated static func freshProfile(in folder: URL, files: FileManager = .default) -> Bool {
        !profileFiles.contains { files.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    nonisolated static let launchedFresh: Bool = freshProfile(in: Store.folder)

    var showing: Bool { phase != .away }
    var index: Int { steps.firstIndex(of: step) ?? 0 }
    var seen: Bool { settings.bool(forKey: Self.seenKey) }

    @discardableResult
    func arrive(in browser: Browser, testing: Bool = Store.testing, freshProfile: Bool = Onboarding.launchedFresh) -> Bool {
        guard !arrived else { return showing }
        arrived = true
        let forced = settings.bool(forKey: Self.showKey)
        let begun = settings.bool(forKey: Self.begunKey)
        guard Self.due(testing: testing, forced: forced, seen: seen, freshProfile: freshProfile, begun: begun) else {
            if !testing, !seen { settings.set(true, forKey: Self.seenKey) }
            return false
        }
        if forced, !testing { settings.removeObject(forKey: Self.showKey) }
        begin(in: browser)
        return true
    }

    func begin(in browser: Browser, reduced: Bool = Motion.reduced) {
        guard phase == .away else { return }
        self.browser = browser
        settings.set(true, forKey: Self.begunKey)
        score = .current(reduced: reduced)
        steps = Step.allCases.filter { $0 != .links || !isDefault() }
        step = steps.first ?? .space
        defaultAsked = false
        bringing = nil
        keyTyped = ""
        keyNote = nil
        name = browser.space.name
        look = SpaceLook.opening(for: browser.space.look)
        side = browser.prefs.sidePosition
        source = ImportSource.firstPick(in: sources(), defaultBrowser: defaultBrowser())
        runs += 1
        phase = .intro
        stage?.raise(self)
        let run = runs
        after(score.ends) { [weak self] in
            guard let self, self.runs == run else { return }
            self.endIntro()
        }
    }

    static func replay() {
        shared.stage = OnboardingShow.shared
        shared.begin(in: Browsers.acting)
    }

    func abandon() {
        runs += 1
        phase = .away
        stage?.clear()
    }

    func open(at wanted: Step, in browser: Browser) {
        self.browser = browser
        steps = Step.allCases
        step = wanted
        name = browser.space.name
        look = SpaceLook.opening(for: browser.space.look)
        side = browser.prefs.sidePosition
        source = ImportSource.firstPick(in: sources(), defaultBrowser: defaultBrowser())
        runs += 1
        phase = .steps
    }

    func endIntro() {
        guard phase == .intro else { return }
        phase = .steps
    }

    func go(_ wanted: Step) {
        guard phase == .steps, steps.contains(wanted) else { return }
        step = wanted
    }

    func primary() {
        guard phase == .steps else { return }
        switch step {
        case .space:
            paintSpace()
            advance()
        case .side:
            browser?.prefs.sidePosition = side
            advance()
        case .links:
            defaultAsked = true
            stage?.makeWay()
            askDefault { [weak self] in self?.stage?.takeBack() }
            advance()
        case .agents:
            browser?.prefs.agentsOn = true
            advance()
        case .key:
            addKey()
        case .bring:
            finish(bringing: source)
        }
    }

    func later() {
        guard phase == .steps else { return }
        advance()
    }

    func close() {
        guard phase == .intro || phase == .steps else { return }
        finish(bringing: nil)
    }

    func openKeysPage() {
        opened.append(AIGroupWords.keysPage)
        openLink(AIGroupWords.keysPage)
    }

    private func addKey() {
        let typed = OpenRouterKey.plain(keyTyped)
        guard !typed.isEmpty else {
            advance()
            return
        }
        guard keys.state != .checking else { return }
        keyNote = AIGroupWords.checking
        let run = runs
        Task { [weak self] in
            guard let self else { return }
            let saved = await self.keys.save(typed)
            guard self.runs == run, self.phase == .steps else { return }
            if saved {
                self.keyTyped = ""
                self.keyNote = nil
                if self.step == .key { self.advance() }
            } else {
                self.keyNote = self.keys.trouble ?? OpenRouterTrouble.nonsense.words
            }
        }
    }

    private func advance() {
        let next = index + 1
        if steps.indices.contains(next) { step = steps[next] } else { finish(bringing: nil) }
    }

    private func paintSpace() {
        guard let browser else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, typed != browser.space.name { browser.renameSpace(browser.spaceID, to: typed) }
        guard look != SpaceLook.offeredID(of: browser.space.look), let wanted = SpaceLook.offered(look) else { return }
        browser.setSpaceLook(browser.spaceID, to: wanted)
    }

    private func finish(bringing wanted: String?) {
        settings.set(true, forKey: Self.seenKey)
        settings.removeObject(forKey: Self.begunKey)
        bringing = wanted
        phase = .leaving
        runs += 1
        if let wanted { browser?.bringingIn = wanted }
        guard let stage else {
            phase = .away
            return
        }
        let run = runs
        stage.handOff(self) { [weak self] in
            guard let self, self.runs == run, self.phase == .leaving else { return }
            self.phase = .away
        }
    }

    func takes(_ event: NSEvent) -> Bool {
        guard showing, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            if typed == "w" || typed == "." {
                close()
                return true
            }
            return !Self.passing.contains(typed)
        }
        if flags.contains(.command) || flags.contains(.control) { return true }
        switch (phase, event.keyCode) {
        case (.intro, 36), (.intro, 76), (.intro, 53), (.intro, 49): endIntro()
        case (.steps, 36), (.steps, 76): primary()
        case (.steps, 53): later()
        case (.intro, _), (.leaving, _): break
        default: return false
        }
        return true
    }

    nonisolated static func title(_ step: Step) -> String {
        switch step {
        case .space: return "Name your first space"
        case .side: return "Which side for your tabs?"
        case .links: return "Open links in Broadway?"
        case .agents: return "Let agents use Broadway?"
        case .key: return AIGroupWords.stepTitle
        case .bring: return "Bring your things over"
        }
    }

    nonisolated static func line(_ step: Step) -> String {
        switch step {
        case .space: return "A space keeps its own tabs, pins and look. Start with one and add more whenever you like."
        case .side: return "Tabs live in a sidebar. Put it where your hand goes. You can move it later in Settings."
        case .links: return "Links from mail, chats and other apps can open right here. macOS will ask to be sure."
        case .agents: return "Coding agents and your own scripts can open pages, read them and click for you. It stays off until you turn it on."
        case .key: return AIGroupWords.stepLine(mac: true, remoteDecides: false)
        case .bring: return "Bookmarks, history and more, from the browser you used before. Nothing leaves your Mac."
        }
    }

    func lead(_ step: Step) -> String {
        switch step {
        case .space, .side: return "Continue"
        case .links: return "Make Broadway Default"
        case .agents: return "Turn On Agents"
        case .key: return OpenRouterKey.plain(keyTyped).isEmpty ? "Continue" : "Add Key"
        case .bring: return source.isEmpty ? "Bring Things Over" : "Bring Over from \(source)"
        }
    }
}

@MainActor
enum OnboardingSurface {
    static func make(_ request: [String: Any]) -> NSView {
        let onboarding = Onboarding(settings: UserDefaults(suiteName: "onboarding.surface.\(UUID().uuidString)") ?? .standard)
        let index = (request["step"] as? Int ?? 1) - 1
        let step = Onboarding.Step.allCases.indices.contains(index) ? Onboarding.Step.allCases[index] : .space
        onboarding.open(at: step, in: Browsers.primary ?? Browsers.acting)
        if let note = request["keyNote"] as? String { onboarding.keyNote = note }
        if let source = request["source"] as? String { onboarding.source = source }
        let view = OnboardingView(onboarding: onboarding)
        view.kitSize(width: CGFloat(request["width"] as? Double ?? 760), height: CGFloat(request["height"] as? Double ?? 680))
        return view
    }
}
