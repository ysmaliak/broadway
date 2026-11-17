import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class HookGateTests {
    private let lab: HookLab

    init() throws {
        let lab = try HookLab("gate")
        self.lab = lab
        addTeardownBlock { lab.close() }
    }

    private func recorder(_ name: String, answer: String = "{}") throws -> URL {
        try lab.program(name, "cat > '\(lab.path(name + ".in"))'\necho '\(answer)'")
    }

    @Test func aProgramsAnswerIsRead() async throws {
        try lab.add(.link, recorder("speaks", answer: #"{"say": "hello"}"#))

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == "hello")
        #expect(lab.json("speaks.in")?["event"] as? String == "link")
        #expect(lab.json("speaks.in")?["version"] as? Int == 1)
    }

    @Test func limit2AnAgentsTabRaisesNoEvent() async throws {
        try lab.add(.permission, recorder("agent", answer: #"{"answer": "allow"}"#))

        let said = await lab.permission(scene: HookScene(agent: true))

        #expect(said == nil)
        #expect(!lab.exists("agent.in"))
        #expect(HookGate.asked.isEmpty)
    }

    @Test func limit2ATabAnAgentIsWorkingInIsAnAgentsScene() {
        let tab = Tab(bench: false)
        tab.agent = true
        defer { tab.agent = false }

        let scene = HookScene.of(tab, in: nil)

        #expect(scene?.agent == true)
        #expect(scene?.allowed == false)
    }

    @Test func limit2ADownloadAnAgentWatchesRaisesNoEvent() {
        #expect(!HookDownloads.eligible(asksWhereToSave: false, privateWindow: false, agentDownload: true))
        #expect(HookDownloads.eligible(asksWhereToSave: false, privateWindow: false, agentDownload: false))
    }

    @Test func limit3ADownloadPlacedByAskFirstRaisesNoEvent() {
        #expect(!HookDownloads.eligible(asksWhereToSave: true, privateWindow: false, agentDownload: false))
    }

    @Test func limit3TheOnlyEventsAreLinksDownloadsSiteRequestsAndATimer() {
        #expect(HookEvent.allCases == [.link, .download, .permission, .timer])
        #expect(HookEvent.allCases.filter(\.deciding) == [.link, .permission])
    }

    @Test func limit3APermissionHookAnswersOnlyTheCameraMicrophoneLocationAndNotifications() async throws {
        try lab.add(.permission, recorder("asks", answer: #"{"answer": "allow"}"#))

        let said = await lab.permission(wants: [])

        #expect(said == nil)
        #expect(!lab.exists("asks.in"))
        #expect(HookAsk.wants(.cameraAndMicrophone) == ["camera", "microphone"])
    }

    @Test func limit4APrivateTabRaisesNoEvent() async throws {
        try lab.add(.permission, recorder("private", answer: #"{"answer": "allow"}"#))
        let tab = Tab(shy: true)

        let said = await lab.permission(scene: HookScene.of(tab, in: nil))

        #expect(HookScene.of(tab, in: nil)?.privately == true)
        #expect(said == nil)
        #expect(!lab.exists("private.in"))
    }

    @Test func limit4ADownloadInAPrivateWindowRaisesNoEvent() {
        #expect(!HookDownloads.eligible(asksWhereToSave: false, privateWindow: true, agentDownload: false))
    }

    @Test func aTabNobodyCanPlaceRaisesNoEvent() async throws {
        try lab.add(.permission, recorder("nobody", answer: #"{"answer": "allow"}"#))

        let said = await lab.permission(scene: nil)

        #expect(said == nil)
        #expect(!lab.exists("nobody.in"))
    }

    @Test func aScriptsTabRaisesNoEvent() async throws {
        try lab.add(.permission, recorder("bench", answer: #"{"answer": "allow"}"#))

        let said = await lab.permission(scene: HookScene.of(Tab(bench: true), in: nil))

        #expect(said == nil)
        #expect(!lab.exists("bench.in"))
    }

    @Test func limit5AnAddressWithQuotesSpacesAndShellCharactersArrivesWholeAsData() async throws {
        let mark = lab.path("ran-from-the-address")
        let address = #"https://example.com/a b?q="x"&r='y';touch "# + mark + #"&s=$(touch "# + mark + #")&t=`touch "# + mark + "`|x>y"
        try lab.add(.link, recorder("data"))

        _ = await lab.ask(.link, ["url": address, "from": "com.example.mail", "space": "Work"], read: HookLab.anything)

        #expect(lab.json("data.in")?["url"] as? String == address)
        #expect(!FileManager.default.fileExists(atPath: mark))
    }

    @Test func limit5NothingAPageControlsReachesTheArgumentsOrTheEnvironment() async throws {
        let site = "evil.example.com;echo pwned"
        try lab.add(.download, lab.program("looks", #"echo "$#|$*" > "# + "'\(lab.path("looks.args"))'\nenv > '\(lab.path("looks.env"))'\ncat > /dev/null\necho '{}'"))

        _ = await lab.ask(.download, ["file": "/tmp/report \"final\".pdf", "site": site, "type": "application/pdf", "size": 1],
                          read: { _ -> HookReading<URL> in .nothing })

        #expect(lab.read("looks.args") == "0|\n")
        let env = try #require(lab.read("looks.env"))
        #expect(!env.contains("evil.example.com"))
        #expect(!env.contains("report"))
    }

    @Test func limit6TheProgramStartsByItselfWithNoArgumentsAFixedEnvironmentAndHomeAsItsFolder() async throws {
        try lab.add(.timer, lab.program("alone", "echo \"$#\" > '\(lab.path("alone.count"))'\npwd -P > '\(lab.path("alone.where"))'\nenv > '\(lab.path("alone.env"))'"))

        _ = await lab.ask(.timer, ["time": "2026-01-01T00:00:00Z", "minutes": 15], read: { _ -> HookReading<Bool> in .nothing })

        #expect(lab.read("alone.count") == "0\n")
        #expect(lab.read("alone.where")?.trimmingCharacters(in: .newlines) == lab.home.resolvingSymlinksInPath().path)
        let names = Set((lab.read("alone.env") ?? "").split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(names.subtracting(["PWD", "SHLVL", "_", "OLDPWD"]) == ["HOME", "PATH", "LANG", "TMPDIR"])
        #expect((lab.read("alone.env") ?? "").contains("HOME=\(lab.home.path)"))
        #expect((lab.read("alone.env") ?? "").contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
    }

    @Test func limit6TheRunnerNeverGoesThroughAShell() {
        let outcome = HookRunner.run(URL(fileURLWithPath: "/bin/echo hello"), input: Data(), seconds: 1, home: lab.home)

        guard case .notStarted = outcome.end else {
            Issue.record("a path with a space was split into words: \(outcome)")
            return
        }
    }

    @Test func limit7AChangedProgramDoesNotAnswerAPermission() async throws {
        let program = try recorder("bound", answer: #"{"answer": "allow"}"#)
        let hook = try lab.add(.permission, program)
        try lab.program("bound", "cat > '\(lab.path("bound.in"))'\necho '{\"answer\": \"deny\"}'")

        let said = await lab.permission()

        #expect(said == nil)
        #expect(!lab.exists("bound.in"))
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "Changed since you approved it")
        #expect(HookWords.needsApproval(try #require(lab.book.hook(hook.id)), book: lab.book))
    }

    @Test func limit7ApprovingAgainLetsTheChangedProgramAnswer() async throws {
        let hook = try lab.add(.permission, recorder("again", answer: #"{"answer": "allow"}"#))
        try lab.program("again", "echo '{\"answer\": \"deny\"}'")
        _ = await lab.permission()

        lab.book.approve(hook.id)
        let said = await lab.permission()

        #expect(said == false)
        #expect(!HookWords.needsApproval(try #require(lab.book.hook(hook.id)), book: lab.book))
    }

    @Test func limit7APermissionHookRunsACopyOfTheBytesItChecked() async throws {
        try lab.add(.permission, lab.program("copy", "echo \"$0\" > '\(lab.path("copy.self"))'\necho '{\"answer\": \"deny\"}'"))

        let said = await lab.permission()

        #expect(said == false)
        let ran = try #require(lab.read("copy.self")).trimmingCharacters(in: .newlines)
        #expect(ran.hasPrefix(HookGate.room.path))
        #expect(!FileManager.default.fileExists(atPath: ran))
    }

    @Test func limit7OtherKindsOfHookRunAsTheFileStands() async throws {
        try lab.add(.link, recorder("loose", answer: #"{"say": "before"}"#))
        try lab.program("loose", #"echo '{"say": "after"}'"#)

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == "after")
    }

    @Test func limit9ASlowProgramIsPassedOverAfterASecond() async throws {
        let hook = try lab.add(.link, lab.program("slow", "sleep 20\necho '{\"say\": \"late\"}'"))
        let start = Date()

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == nil)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "Timed out")
    }

    @Test func limit9ASlowProgramIsStoppedWithWhatItStarted() async throws {
        let child = lab.path("child.pid")
        try lab.add(.link, lab.program("parent", "sleep 30 &\necho $! > '\(child)'\nwait"))

        _ = await lab.ask(.link, read: HookLab.anything)

        let text = try #require(lab.read("child.pid"))
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await hookSoon(3) { kill(pid, 0) != 0 })
    }

    @Test func limit9ThreeTimeOutsInARowSwitchTheHookOff() async throws {
        let hook = try lab.add(.link, lab.program("stuck", "sleep 20"))

        for _ in 0..<3 { _ = await lab.ask(.link, read: HookLab.anything) }

        let now = try #require(lab.book.hook(hook.id))
        #expect(!now.on)
        #expect(lab.book.line(now) == "Switched off after three time-outs or crashes in a row")
        #expect(lab.book.ready(for: .link).isEmpty)
    }

    @Test func limit9ThreeCrashesInARowSwitchTheHookOff() async throws {
        let hook = try lab.add(.link, lab.program("crashes", "kill -SEGV $$"))

        for _ in 0..<3 { _ = await lab.ask(.link, read: HookLab.anything) }

        #expect(lab.book.hook(hook.id)?.on == false)
        #expect(lab.book.hook(hook.id)?.off == HookBook.switchedOff)
    }

    @Test func limit9ARunThatWorksBetweenMissesStartsTheCountAgain() async throws {
        let hook = try lab.add(.link, lab.program("sometimes", "kill -SEGV $$"))
        for _ in 0..<2 { _ = await lab.ask(.link, read: HookLab.anything) }
        try lab.program("sometimes", "echo '{}'")
        _ = await lab.ask(.link, read: HookLab.anything)
        try lab.program("sometimes", "kill -SEGV $$")

        for _ in 0..<2 { _ = await lab.ask(.link, read: HookLab.anything) }

        #expect(lab.book.hook(hook.id)?.on == true)
    }

    @Test func aProgramThatPrintsSomethingElseIsPassedOver() async throws {
        let hook = try lab.add(.link, lab.program("chatty", "echo 'Opening Reading now'"))

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == nil)
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "Its answer wasn't a JSON object")
    }

    @Test func anExitCodeOtherThanZeroCountsAsNothing() async throws {
        let hook = try lab.add(.link, lab.program("fails", "echo '{\"say\": \"no\"}'\nexit 3"))

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == nil)
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "Exited with code 3")
        #expect(lab.book.hook(hook.id)?.on == true)
    }

    @Test func anAnswerOverSixtyFourKilobytesCountsAsNothing() async throws {
        let hook = try lab.add(.link, lab.program("long", #"printf '{"say": "'; head -c 70000 /dev/zero | tr '\0' 'a'; printf '"}'"#))

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == nil)
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "Its answer was over 64 KB")
    }

    @Test func onlyTheLastTwoKilobytesOfStandardErrorAreKept() async throws {
        let hook = try lab.add(.link, lab.program("complains", "head -c 5000 /dev/zero | tr '\\0' 'x' >&2\necho >&2\necho 'the end' >&2\nexit 1"))

        _ = await lab.ask(.link, read: HookLab.anything)

        let said = try #require(lab.book.results[hook.id]?.said)
        #expect(said.utf8.count == 2048)
        #expect(said.hasSuffix("the end\n"))
        let detail = HookWords.detail(try #require(lab.book.hook(hook.id)), book: lab.book)
        #expect(detail.hasSuffix("Exited with code 1. It said: the end"), "\(detail)")
    }

    @Test func aProgramThatNeverReadsItsInputLeavesBroadwayStanding() async throws {
        try lab.add(.link, lab.program("deaf", "exit 0"))
        let big = String(repeating: "a", count: 1_000_000)

        let said = await lab.ask(.link, ["url": "https://example.com/" + big], read: HookLab.anything)

        #expect(said == nil)
    }

    @Test func aProgramThatIsNotThereAnyMoreIsPassedOver() async throws {
        let program = try lab.program("gone", "echo '{}'")
        let hook = try lab.add(.link, program)
        try FileManager.default.removeItem(at: program)

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == nil)
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "The program isn't there any more")
    }

    @Test func hooksAreAskedInOrderAndTheFirstAnswerThatIsNotNothingWins() async throws {
        try lab.add(.link, recorder("first", answer: "{}"))
        try lab.add(.link, recorder("second", answer: #"{"say": "second"}"#))
        try lab.add(.link, recorder("third", answer: #"{"say": "third"}"#))

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == "second")
        #expect(lab.exists("first.in"))
        #expect(!lab.exists("third.in"))
    }

    @Test func aHookThatIsOffIsNotAsked() async throws {
        let hook = try lab.add(.link, recorder("asleep", answer: #"{"say": "awake"}"#))
        lab.book.turn(hook.id, on: false)

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == nil)
        #expect(!lab.exists("asleep.in"))
    }

    @Test func limit10ATestWorldRunsNoProgramOutsideItsOwnFolder() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("hook-outside-\(UUID().uuidString.prefix(8))")
        try "#!/bin/sh\necho '{\"say\": \"outside\"}'\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        defer { try? FileManager.default.removeItem(at: outside) }
        try lab.add(.link, outside)

        let said = await lab.ask(.link, read: HookLab.anything)

        #expect(said == nil)
        #expect(!HookGate.allows(outside))
        #expect(HookGate.asked.isEmpty)
    }

    @Test func limit10ATestWorldsHooksComeFromItsOwnFile() {
        #expect(HookBook.shared.file == Store.file("hooks.json"))
        #expect(HookBook.shared.file.path.hasPrefix(Store.folder.path))
        #expect(Store.world != nil)
    }
}
