import AppKit
import UniformTypeIdentifiers
import WebKit

struct SiteAction: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let prompt: String
    var drafts = false

    static let sumUp = SiteAction(title: "Sum it up", prompt: "Sum this page up in a few sentences, or up to six short points if it covers several things.")

    @MainActor
    static func offered(for url: URL?, skills: SkillStore = .shared) -> [SiteAction] {
        [sumUp] + skills.actions(for: url).filter { $0.title != sumUp.title }
    }
}

struct AskProblem: Equatable {
    let title: String
    let detail: String?

    @MainActor
    static func of(_ failed: String, plan: Plan?, other: Plan?) -> AskProblem {
        guard let plan else { return AskProblem(title: failed, detail: nil) }
        let name = plan.tool
        if failed == ProviderError.notInstalled(plan).localizedDescription {
            return AskProblem(title: "\(name) isn't on this Mac", detail: "Install it and sign in, then ask again")
        }
        if failed == ProviderError.notSignedIn(plan).localizedDescription {
            return AskProblem(title: "\(name) is signed out", detail: "Run \(plan.signIn) in Terminal, then ask again")
        }
        if !Plans.shared.hasRoom(plan) || failed == ProviderError.planOut("").localizedDescription {
            let next = other.map { "Ask \($0.tool) with ⇧⌘R, or try again later" } ?? "Try again later"
            return AskProblem(title: "\(name) has reached its limit for now", detail: next)
        }
        let said = failed.trimmingCharacters(in: .whitespacesAndNewlines)
        return AskProblem(title: "\(name) couldn't answer", detail: said.isEmpty ? nil : String(said.prefix(240)))
    }
}

extension Browser {
    func summarizePage() {
        guard prefs.askAndChat, let tab = active, tab.isWeb else { return }
        Task { @MainActor in
            await openLine(tab)
            guard let line = ai.line, line.tab == tab.id, line.onPage else { return }
            line.run(SiteAction.sumUp.prompt)
        }
    }

    func siteActions(for line: PageAsk) -> [SiteAction] {
        guard line.onPage, line.takes, !line.answering else { return [] }
        return SiteAction.offered(for: tabs.first { $0.id == line.tab }?.pageAddress)
    }

    func putAnswerInPage(_ line: PageAsk) {
        guard let tab = tabs.first(where: { $0.id == line.tab }), let text = line.conversation.lastAnswer?.text, !text.isEmpty else { return }
        Task { @MainActor in
            let put = await PageSelection.putInBox(text, tab: tab)
            announce(put ? "Put in the page" : "Click into a box on the page first")
            if put { closeLine() }
        }
    }

    func otherAgent(for line: PageAsk) -> ModelChoice? {
        guard !line.blind, let plan = line.agent, Plan.cloud.contains(plan), Plans.shared.connected(plan.other) else { return nil }
        return Plans.shared.defaultChoice(plan.other)
    }

    func askOtherAgent(_ line: PageAsk) {
        guard !line.conversation.running, line.answering else { return }
        guard let other = otherAgent(for: line) else { return announce("No other agent is signed in") }
        line.conversation.use(other)
        line.conversation.askAgain()
    }

    func addableTabs(for line: PageAsk) -> [Tab] {
        guard line.takes, !line.blind else { return [] }
        return tabs.filter { tab in
            tab.canBeRead && !tab.asksAgent && !line.conversation.attachments.contains { $0.kind == .tab(tab.id) }
        }
    }

    func canShoot(for line: PageAsk) -> Bool {
        guard line.takes, !line.blind, line.agent != .thisMac, let tab = tabs.first(where: { $0.id == line.tab }) else { return false }
        return tab.canBeRead && !line.conversation.attachments.contains { $0.label == "Screenshot" }
    }

    func addMenu(for line: PageAsk) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tabs = addableTabs(for: line)
        if !tabs.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Tabs"))
            for tab in tabs {
                let title = tab.title.isEmpty ? tab.pageAddress?.host() ?? "Page" : tab.title
                menu.addItem(AskMenuItem(title) { [weak line] in
                    line?.conversation.attachments.append(Attachment(label: title, kind: .tab(tab.id)))
                })
            }
            menu.addItem(.separator())
        }
        if canShoot(for: line) {
            menu.addItem(AskMenuItem("Screenshot of This Page") { [weak self, weak line] in
                guard let self, let line else { return }
                Task { @MainActor in await self.attachScreenshot(to: line) }
            })
        }
        menu.addItem(AskMenuItem("File…") { [weak self, weak line] in
            guard let self, let line else { return }
            self.attachFile(to: line)
        })
        return menu
    }

    func pageShot(_ tab: Tab) async -> Data? {
        guard tab.canBeRead, let web = tab.built else { return nil }
        let hidden = await PageSelection.hideSecrets(tab)
        guard hidden else { return nil }
        let image: NSImage? = await withCheckedContinuation { done in
            web.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in done.resume(returning: image) }
        }
        await PageSelection.showSecrets(tab)
        guard let image, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    func attachScreenshot(to line: PageAsk) async {
        guard canShoot(for: line), let tab = tabs.first(where: { $0.id == line.tab }) else { return }
        guard let png = await pageShot(tab) else { return announce("No picture of this page") }
        let file = CLIFinder.room.appendingPathComponent("shot-\(UUID().uuidString).png")
        guard (try? png.write(to: file)) != nil else { return }
        line.conversation.attachments.append(Attachment(label: "Screenshot", kind: .image(file, "image/png")))
    }

    func attachFile(to line: PageAsk) {
        guard line.takes else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let attachment = Browser.attachment(file: file, pictures: line.agent != .thisMac) else {
            return announce("That file can't be read as text or a picture")
        }
        line.conversation.attachments.append(attachment)
    }

    nonisolated static func attachment(file: URL, pictures: Bool = true) -> Attachment? {
        let type = UTType(filenameExtension: file.pathExtension)
        if let type, type.conforms(to: .image) {
            guard pictures, let media = type.preferredMIMEType else { return nil }
            return Attachment(label: file.lastPathComponent, kind: .image(file, media))
        }
        guard let data = try? Data(contentsOf: file), data.count < 2_000_000, let text = String(data: data, encoding: .utf8) else { return nil }
        return Attachment(label: file.lastPathComponent, kind: .text(String(text.prefix(AIPage.limit))))
    }
}

final class AskMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(go), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func go() { run() }

    func perform() { run() }
}
