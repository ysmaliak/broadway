import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TextCommandTests {
    private var fake: FakeProvider!
    private let picked = PickedText(text: "SELECTED WORDS", kind: .page, editable: false, box: .zero, family: "", size: 14)

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        fake = FakeProvider(plan: .claude, echoes: true)
        Plans.shared.standIn(fake, for: .claude)
        Plans.shared.standIn(FakeProvider(plan: .chatGPT, echoes: true), for: .chatGPT)
        Plans.shared.standIn(FakeProvider(plan: .thisMac, echoes: true), for: .thisMac)
        await Plans.shared.refresh()
    }

    private func tearDown() async {
        Plan.allCases.forEach { Plans.shared.standIn(nil, for: $0) }
    }

    private func settle(_ run: SelectionRun) async {
        for _ in 0..<500 {
            if !run.running { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("still running")
    }

    @Test func diffMarksWordsAndKeepsSpaces() {
        let pieces = TextDiff.pieces(from: "Their is a mistake", to: "There is a mistake")

        #expect(pieces.filter { $0.kind == .removed }.map(\.text) == ["Their"])
        #expect(pieces.filter { $0.kind == .added }.map(\.text) == ["There"])
        #expect(pieces.filter { $0.kind != .removed }.map { $0.text }.joined() == "There is a mistake")
        #expect(pieces.filter { $0.kind != .added }.map { $0.text }.joined() == "Their is a mistake")
    }

    @Test func diffOfNothingChanged() {
        let pieces = TextDiff.pieces(from: "same words", to: "same words")

        #expect(pieces == [TextDiff.Piece(kind: .same, text: "same words")])
    }

    @Test func templatesNameThingsAndNeverCarryThemInTheOrders() {
        let command = TextCommand(id: "x", name: "X", prompt: "Say {selection} from {page} at {url} in {language}")

        let prompt = command.prompt(language: "French")

        #expect(prompt == "Say the selected text from the page at the page's address in French")
        #expect(command.wantsPage)
        #expect(command.wantsAddress)
        #expect(!TextCommand.standard[0].wantsPage)
    }

    @Test func fitsKindsAndSites() {
        var command = TextCommand(id: "x", name: "X", prompt: "{selection}")
        command.kinds = [.code]
        var boxed = command
        boxed.kinds = Set(PickedText.Kind.allCases)
        boxed.sites = ["github.com"]

        #expect(command.fits(picked, host: "a.example") == false)
        #expect(boxed.fits(picked, host: "gist.github.com") == true)
        #expect(boxed.fits(picked, host: "notgithub.com") == false)
        #expect(boxed.fits(picked, host: nil) == false)
    }

    @Test func runFencesTheSelectionWithNoTools() async {
        let run = SelectionRun(command: TextCommand.standard[3], asked: "Summarize it", picked: picked, tab: Tab(),
                               choice: ModelChoice(plan: .claude, model: "fake", effort: nil))

        run.start()
        await settle(run)

        let request = fake.requests.last
        #expect(request?.tools == ProviderTools.none)
        let prompt = request?.prompt ?? ""
        #expect(prompt.range(of: "SELECTED WORDS")!.lowerBound < prompt.range(of: "My request is")!.lowerBound)
        #expect(prompt.hasPrefix("<page-"))
        #expect(run.text.hasPrefix("Fake answer:"))
    }

    @Test func followUpCarriesWhatWasSaid() async {
        let run = SelectionRun(command: TextCommand.standard[3], asked: "Summarize it", picked: picked, tab: Tab(),
                               choice: ModelChoice(plan: .claude, model: "fake", effort: nil))
        run.start()
        await settle(run)

        run.draft = "shorter please"
        run.followUp()
        await settle(run)

        let prompt = fake.requests.last?.prompt ?? ""
        #expect(prompt.contains("I said: Summarize it"))
        #expect(prompt.hasSuffix("shorter please"))
    }

    @Test func retryOnAnotherModel() async {
        let other = FakeProvider(plan: .chatGPT, echoes: true)
        Plans.shared.standIn(other, for: .chatGPT)
        await Plans.shared.refresh()
        let prefs = Preferences()
        let first = ModelChoice(plan: .claude, model: "fake", effort: nil)
        let run = SelectionRun(command: TextCommand.standard[3], asked: "Do it", picked: picked, tab: Tab(), choice: first)
        run.start()
        await settle(run)

        let next = Plans.shared.otherChoice(than: first, prefs)
        run.retry(on: next)
        await settle(run)

        #expect(next?.plan == .chatGPT)
        #expect(other.requests.count == 1)
    }

    @Test func storeKeepsMineAndTheOptionalOnes() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("broadway-commands-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let suite = "broadway.commands.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        addTeardownBlock { removeTestDefaults(defaults, suite: suite) }
        let store = CommandStore(file: file, defaults: defaults)
        var command = TextCommand(id: "mine", name: "Pirate", prompt: "As a pirate: {selection}")
        command.output = .copied

        store.save(command)
        store.toggle("define", on: true)
        Disk.drain()
        let again = CommandStore(file: file, defaults: defaults)

        #expect(again.mine.map(\.name) == ["Pirate"])
        #expect(again.mine[0].mine)
        #expect(again.mine[0].output == .copied)
        #expect(again.active.contains { $0.id == "define" })
        #expect(!again.active.contains { $0.id == "shorter" })

        again.delete("mine")

        #expect(again.mine.isEmpty)
    }

    @Test func everyStandardCommandHasACommandWithNoKeyInTheEditGroup() throws {
        for command in TextCommand.standard {
            let made = try #require(Command.named("edit.text.\(command.id)"))
            #expect(made.title == command.name)
            #expect(made.section == .edit)
            #expect(made.defaultKey == nil)
        }
        let more = try #require(Command.named("edit.text.more"))
        #expect(more.title == "More Commands…")
        #expect(more.defaultKey == nil)
        #expect(Command.named("edit.draftForm") == nil)
        #expect(Command.named("view.routines") == nil)
    }
}
