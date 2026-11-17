import Foundation
import Testing
@testable import Search

@Suite("Hints")
struct HintsTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute, second: second))!
    }

    let start = at(10, 9)
    let now = at(10, 10)

    static func defaults(_ id: String) -> KeyCombo? { Command.named(id)?.defaultKey }

    func due(_ id: HintID, record: HintRecord = HintRecord(), trail: HintTrail = HintTrail(), scene: HintScene = HintScene(),
             now: Date? = nil, launched: Date? = nil, key: @escaping (String) -> KeyCombo? = defaults) -> String? {
        Hints.due(id, record: record, trail: trail, scene: scene, now: now ?? self.now, launched: launched ?? start,
                  calendar: Self.calendar, key: key)
    }

    func notes(_ events: [(HintEvent, Date)], trail: HintTrail = HintTrail()) -> [HintID?] {
        var trail = trail
        return events.map { Hints.note($0.0, trail: &trail, now: $0.1) }
    }

    func switches(_ count: Int, every seconds: Double, pair: (UUID, UUID) = (UUID(), UUID()), splitOn: Bool = true,
                  inSplit: Bool = false) -> [HintID?] {
        notes((0..<count).map { step in
            let forth = step % 2 == 0
            return (.switched(from: forth ? pair.0 : pair.1, to: forth ? pair.1 : pair.0, splitOn: splitOn, eitherInSplit: inSplit),
                    now.addingTimeInterval(Double(step) * seconds))
        })
    }

    @Test("three tabs closed with the pointer within ten minutes make the close hint due")
    func threePointerClosesAreDue() {
        let found = notes([(.closedByPointer, now), (.closedByPointer, now + 200), (.closedByPointer, now + 590)])

        #expect(found == [nil, nil, .close])
    }

    @Test("two tabs closed with the pointer are not enough")
    func twoPointerClosesAreNot() {
        #expect(notes([(.closedByPointer, now), (.closedByPointer, now + 5)]) == [nil, nil])
    }

    @Test("three pointer closes spread over more than ten minutes are not due")
    func slowPointerClosesAreNot() {
        let found = notes([(.closedByPointer, now), (.closedByPointer, now + 300), (.closedByPointer, now + 601)])

        #expect(found == [nil, nil, nil])
    }

    @Test("History opened within twenty seconds of a close makes the reopen hint due")
    func historySoonAfterCloseIsDue() {
        #expect(notes([(.closedTab, now), (.openedHistory, now + 20)]) == [nil, .reopen])
    }

    @Test("the closed tab's address typed within twenty seconds makes the reopen hint due")
    func typedSoonAfterCloseIsDue() {
        #expect(notes([(.closedTab, now), (.typedClosedAddress, now + 12)]) == [nil, .reopen])
    }

    @Test("History opened after twenty seconds, or with nothing closed, is not due")
    func historyLateIsNot() {
        #expect(notes([(.closedTab, now), (.openedHistory, now + 21)]) == [nil, nil])
        #expect(notes([(.openedHistory, now)]) == [nil])
    }

    @Test("six switches back and forth between two tabs within two minutes make the split hint due")
    func sixSwitchesAreDue() {
        let found = switches(6, every: 20)

        #expect(found.last == .split)
        #expect(found.dropLast().allSatisfy { $0 == nil })
    }

    @Test("five switches are not enough for the split hint")
    func fiveSwitchesAreNot() {
        #expect(switches(5, every: 10).allSatisfy { $0 == nil })
    }

    @Test("six switches spread over more than two minutes are not due")
    func slowSwitchesAreNot() {
        #expect(!switches(6, every: 25).contains(.split))
    }

    @Test("a switch to a third tab starts the count again")
    func thirdTabBreaksTheRun() {
        let a = UUID(), b = UUID(), c = UUID()
        var trail = HintTrail()
        let steps: [(UUID, UUID)] = [(a, b), (b, a), (a, c), (c, a), (a, b), (b, a), (a, b), (b, a)]
        let found = steps.enumerated().map { index, step in
            Hints.note(.switched(from: step.0, to: step.1, splitOn: true, eitherInSplit: false), trail: &trail, now: now + Double(index))
        }

        #expect(found.allSatisfy { $0 == nil })
    }

    @Test("the split hint is not due with Split View off or with a tab already in a pair")
    func splitNeedsSplitViewAndLoneTabs() {
        #expect(!switches(6, every: 5, splitOn: false).contains(.split))
        #expect(!switches(6, every: 5, inSplit: true).contains(.split))
    }

    @Test("an address with tracking copied from the field makes the clean hint due")
    func trackedCopyIsDue() {
        #expect(notes([(.copiedTrackedAddress, now)]) == [.clean])
    }

    @Test("three presses of the next arrow in one search make the next hint due")
    func threeNextPressesAreDue() {
        #expect(notes([(.findNextByPointer, now), (.findNextByPointer, now + 1), (.findNextByPointer, now + 2)]) == [nil, nil, .next])
    }

    @Test("a new search starts the next arrow's count again")
    func newSearchResetsTheCount() {
        let found = notes([(.findNextByPointer, now), (.findNextByPointer, now + 1), (.searchChanged, now + 2),
                           (.findNextByPointer, now + 3), (.findNextByPointer, now + 4)])

        #expect(found.allSatisfy { $0 == nil })
    }

    @Test("each hint reads as its line with the command's key as Broadway has it")
    func linesNameTheDefaultKeys() {
        #expect(due(.close) == "⌘W closes the tab in front")
        #expect(due(.reopen) == "⇧⌘T brings back the tab you just closed")
        #expect(due(.split) == "Drag a tab onto the page to see both side by side")
        #expect(due(.clean) == "⌥⇧⌘C copies the link without its tracking")
        #expect(due(.next) == "⌘G goes to the next match")
    }

    @Test("each keyed hint names a real command")
    func commandsExist() {
        for id in HintID.allCases {
            if let command = id.command { #expect(Command.named(command) != nil, "\(command)") }
        }
        #expect(HintID.split.command == nil)
    }

    @Test("a changed key is the key the hint names")
    func changedKeyIsNamed() {
        let line = due(.close, key: { $0 == "file.closeTab" ? KeyCombo("k", option: true) : nil })

        #expect(line == "⌥⌘K closes the tab in front")
    }

    @Test("a hint whose command has no key is not shown")
    func noKeyNoHint() {
        for id in [HintID.close, .reopen, .clean, .next] {
            #expect(due(id, key: { _ in nil }) == nil)
        }
        #expect(due(.split, key: { _ in nil }) != nil)
    }

    @Test("a hint already shown is never shown again")
    func shownOnce() {
        var record = HintRecord()
        var trail = HintTrail()
        Hints.shown(.close, record: &record, trail: &trail, now: Self.at(1, 10))

        #expect(due(.close, record: record) == nil)
        #expect(due(.close, record: record, now: Self.at(25, 10)) == nil)
    }

    @Test("a second hint waits for the next day")
    func oneADay() {
        let record = HintRecord(shown: [.close], last: Self.at(10, 8))

        #expect(due(.reopen, record: record, now: Self.at(10, 23, 59)) == nil)
        #expect(due(.reopen, record: record, now: Self.at(11, 0, 1)) != nil)
    }

    @Test("a window that showed one less than an hour ago shows no other, even on a new day")
    func oneAnHourPerWindow() {
        let shown = Self.at(10, 23, 40)
        let record = HintRecord(shown: [.close], last: shown)
        let trail = HintTrail(lastShown: shown)

        #expect(due(.reopen, record: record, trail: trail, now: Self.at(11, 0, 10)) == nil)
        #expect(due(.reopen, record: record, trail: trail, now: Self.at(11, 0, 41)) != nil)
        #expect(due(.reopen, record: record, trail: HintTrail(), now: Self.at(11, 0, 10)) != nil)
    }

    @Test("nothing is shown in the first two minutes after Broadway starts")
    func notRightAfterStart() {
        #expect(due(.close, now: start + 119) == nil)
        #expect(due(.close, now: start + 120) != nil)
    }

    @Test("a person who used the fast way never gets that hint")
    func usedFastWay() {
        var record = HintRecord()
        Hints.used("file.closeTab", record: &record)
        Hints.used("view.zoomIn", record: &record)

        #expect(record.used == [.close])
        #expect(due(.close, record: record) == nil)
        #expect(due(.reopen, record: record) != nil)
    }

    @Test("each fast way marks its own hint as used")
    func commandsMarkTheirHints() {
        for id in HintID.allCases {
            guard let command = id.command else { continue }
            var record = HintRecord()
            Hints.used(command, record: &record)
            #expect(record.used == [id])
        }
    }

    @Test("nothing is shown while the caret is in a field, in full screen, private, an agent's tab or over another line",
          arguments: [\HintScene.inAddressField, \.inPageBox, \.fullScreen, \.privateWindow, \.agentTab, \.announcing])
    func quietScenes(_ path: WritableKeyPath<HintScene, Bool>) {
        var scene = HintScene()
        scene[keyPath: path] = true

        #expect(due(.close, scene: scene) == nil)
    }

    @Test("an address typed again is the same page with or without www or a last slash")
    func samePage() {
        let closed = URL(string: "https://www.example.com/notes/?id=4")!

        #expect(Hints.samePage(URL(string: "https://example.com/notes?id=4")!, closed))
        #expect(!Hints.samePage(URL(string: "https://example.com/notes?id=5")!, closed))
        #expect(!Hints.samePage(URL(string: "https://example.org/notes?id=4")!, closed))
    }

    @Test("what is kept holds hint ids and a date, nothing else")
    func recordHoldsOnlyIds() throws {
        let record = HintRecord(shown: [.close], used: [.next], last: now)
        let data = try JSONEncoder().encode(record)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(fields.keys) == ["shown", "used", "last"])
        #expect(fields["shown"] as? [String] == ["close"])
        #expect(fields["used"] as? [String] == ["next"])
    }

    @MainActor
    @Test("what was shown is kept with the settings and read back")
    func bookIsKept() throws {
        let name = "hints-tests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }

        HintBook(store: store).change { $0.shown.insert(.reopen) }

        #expect(HintBook(store: store).record.shown == [.reopen])
    }
}
