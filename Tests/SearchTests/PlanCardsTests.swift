import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PlanCardsTests {
    private let max = PlanStatus(path: "/fake/claude", connected: true, account: "Max plan")
    private let chat = PlanStatus(path: "/fake/codex", connected: true, account: "ChatGPT plan")
    private let mac = PlanStatus(path: "Apple Intelligence", connected: true, account: "Apple Intelligence")

    private func card(_ kind: PlanCardKind, in cards: [PlanCard]) throws -> PlanCard {
        try #require(cards.first { $0.kind == kind })
    }

    @Test func theChosenConnectedPlanIsTheDefault() throws {
        let statuses: [Plan: PlanStatus] = [.claude: max, .chatGPT: chat, .thisMac: mac]

        let cards = PlanCards.cards(statuses: statuses, looked: true, chosen: .chatGPT)

        #expect(cards.map(\.kind) == [.claude, .chatGPT, .thisMac])
        #expect(cards.filter { $0.isDefault }.map(\.kind) == [.chatGPT])
        #expect(try card(.claude, in: cards).canBeDefault)
    }

    @Test func aSignedOutChoiceFallsToTheFirstConnectedPlan() throws {
        let statuses: [Plan: PlanStatus] = [.claude: max, .chatGPT: PlanStatus(path: "/fake/codex"), .thisMac: PlanStatus()]

        let cards = PlanCards.cards(statuses: statuses, looked: true, chosen: .chatGPT)

        #expect(cards.filter { $0.isDefault }.map(\.kind) == [.claude])
        #expect(try card(.chatGPT, in: cards).state == .signedOut)
        #expect(try !card(.chatGPT, in: cards).canBeDefault)
    }

    @Test func beforeLookingTheChosenPlanStaysTheDefault() throws {
        let statuses: [Plan: PlanStatus] = [:]

        let cards = PlanCards.cards(statuses: statuses, looked: false, chosen: .chatGPT)

        #expect(try card(.chatGPT, in: cards).state == .looking)
        #expect(cards.filter { $0.isDefault }.map(\.kind) == [.chatGPT])
        #expect(try card(.chatGPT, in: cards).fix == nil)
        #expect(try card(.chatGPT, in: cards).lit)
    }

    @Test func nothingIsTheDefaultWhenNoPlanIsConnected() {
        let statuses: [Plan: PlanStatus] = [.claude: PlanStatus(path: "/fake/claude"), .chatGPT: PlanStatus(), .thisMac: PlanStatus()]

        let cards = PlanCards.cards(statuses: statuses, looked: true, chosen: .claude)

        #expect(cards.allSatisfy { !$0.isDefault })
        #expect(cards.allSatisfy { !$0.canBeDefault })
    }

    @Test func onlyAReadyCloudPlanCanBeChosen() throws {
        let statuses: [Plan: PlanStatus] = [.claude: max, .chatGPT: PlanStatus(), .thisMac: mac]
        let cards = PlanCards.cards(statuses: statuses, looked: true, chosen: .claude)

        let chosen = try PlanCardKind.allCases.map { PlanCards.choose(try card($0, in: cards)) }

        #expect(chosen == [.claude, nil, nil])
        #expect(try card(.thisMac, in: cards).state.ready)
        #expect(try !card(.thisMac, in: cards).isDefault)
    }

    @Test func thisMacIsNeverThePlanDefault() {
        let connected: (Plan) -> Bool = { $0 != .claude }

        let chosen = Plans.defaultPlan(chosen: .thisMac, looked: true, connected: connected)
        let before = Plans.defaultPlan(chosen: .thisMac, looked: false, connected: connected)

        #expect(chosen == .chatGPT)
        #expect(before == .chatGPT)
    }

    @Test func eachMissingProviderOffersTheOneFix() throws {
        let statuses: [Plan: PlanStatus] = [.claude: PlanStatus(), .chatGPT: PlanStatus(path: "/fake/codex"), .thisMac: PlanStatus()]

        let cards = PlanCards.cards(statuses: statuses, looked: true, chosen: nil)

        #expect(try card(.claude, in: cards).fix == .install(Plan.claude.install))
        #expect(try card(.chatGPT, in: cards).fix == .signIn("codex login"))
        #expect(try card(.thisMac, in: cards).fix == .appleIntelligence)
        #expect(cards.allSatisfy { !$0.lit })
        #expect(PlanCardFix.signIn("codex login").command == "codex login")
        #expect(PlanCardFix.appleIntelligence.command == nil)
    }

    @Test func readyProvidersNeedNoFix() throws {
        let statuses: [Plan: PlanStatus] = [.claude: max, .chatGPT: chat, .thisMac: mac]

        let cards = PlanCards.cards(statuses: statuses, looked: true, chosen: nil)

        #expect(cards.allSatisfy { $0.fix == nil && $0.lit })
        #expect(cards.filter { $0.isDefault }.map(\.kind) == [.claude])
    }

    @Test func detailsSayWhatEachCardIs() throws {
        let key = PlanStatus(path: "/fake/claude", connected: true, account: "not a plan: paid per use")
        let statuses: [Plan: PlanStatus] = [.claude: key, .chatGPT: PlanStatus(path: "/fake/codex"), .thisMac: PlanStatus()]

        let cards = PlanCards.cards(statuses: statuses, looked: true, chosen: nil)

        #expect(try card(.claude, in: cards).detail == "Paid per use, not a plan · Claude Code")
        #expect(try card(.chatGPT, in: cards).detail == "Codex is here but not signed in")
        #expect(PlanCard(kind: .chatGPT, state: .missing, isDefault: false).detail == "Codex isn't on this Mac")
        #expect(PlanCard(kind: .claude, state: .ready("Max plan"), isDefault: true).detail == "Max plan · Claude Code")
        #expect(PlanCard(kind: .claude, state: .ready(nil), isDefault: true).detail == "Claude Code")
    }

    @Test func svgPathReadsLinesCurvesAndArcs() {
        let square = "M2 2h10v10H2z"
        let dome = "M0 10a10 10 0 0 1 20 0"
        let packed = "m4.5 4.5.5-.5l1 1"

        let box = SVGPath.read(square).boundingBoxOfPath
        let arc = SVGPath.read(dome).boundingBoxOfPath
        let tight = SVGPath.read(packed).boundingBoxOfPath

        #expect(box == CGRect(x: 2, y: 2, width: 10, height: 10))
        #expect(abs(arc.width - 20) <= 0.01)
        #expect(abs(arc.height - 10) <= 0.05)
        #expect(abs(arc.minY - 0) <= 0.05)
        #expect(tight == CGRect(x: 4.5, y: 4, width: 1.5, height: 1))
    }

    @Test func theProviderLettersStandUprightAndTellApart() {
        let marks = [ProviderMarkView.claudeLetter, ProviderMarkView.chatGPTLetter]

        let bounds = marks.map(\.boundingBoxOfPath)

        for rect in bounds {
            #expect(rect.height > rect.width * 0.9)
            #expect(rect.midY < -5)
        }
        #expect(ProviderMarkView.monogram("").isEmpty)
    }

    @Test func codexNotesComeFromTheCacheButNotEmptyOnes() {
        let cache = #"{"models":[{"slug":"gpt-a","display_name":"GPT A","visibility":"list","description":"Fast and affordable model for easier tasks."},{"slug":"gpt-b","display_name":"GPT B","visibility":"list","description":"GPT B Codex model."}]}"#

        let models = CodexProvider.models(cache: Data(cache.utf8))

        #expect(models.map(\.note) == ["Fast and affordable model for easier tasks", nil])
    }
}
