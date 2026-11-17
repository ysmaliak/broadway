import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct HandoffTests {
    private func offered(_ address: String, privateWindow: Bool = false, agent: Bool = false, own: Bool = false) -> URL? {
        Handoff.offered(URL(string: address), privateWindow: privateWindow, agent: agent, own: own)
    }

    @Test("a web page is offered", arguments: ["https://garden.example/roses", "http://garden.example/"])
    func aWebPageIsOffered(address: String) {
        #expect(offered(address)?.absoluteString == address)
    }

    @Test("these are never offered", arguments: [
        "file:///pages/garden.html", "about:blank", "data:text/html,hello", "ftp://garden.example/",
        "http://localhost:3000/", "http://127.0.0.1:8080/", "http://printer.local/", "http://192.168.1.20/",
        "http://10.0.0.4/", "http://app.localhost/", "https://someone:secret@garden.example/", "https://someone@garden.example/",
    ])
    func neverOffered(address: String) {
        #expect(offered(address) == nil)
    }

    @Test func nothingFromAPrivateWindow() {
        #expect(offered("https://garden.example/", privateWindow: true) == nil)
    }

    @Test func nothingFromAnAgentsTab() {
        #expect(offered("https://garden.example/", agent: true) == nil)
    }

    @Test func nothingFromBroadwaysOwnPages() {
        #expect(offered("https://garden.example/", own: true) == nil)
    }

    @Test func nothingWithNoPage() {
        #expect(Handoff.offered(nil, privateWindow: false, agent: false, own: false) == nil)
    }

    @Test func aTestRunOnlyEverReachesTheStandIn() {
        #expect(Handoff.board === Handoff.standIn)
    }

    @Test func thePageInFrontIsWhatTheStandInIsTold() {
        let before = Handoff.standIn.told.count
        Handoff.standIn.offer(URL(string: "https://garden.example/")!)
        Handoff.standIn.offer(nil)

        #expect(Handoff.standIn.told.dropFirst(before).map { $0?.absoluteString } == ["https://garden.example/", nil])
        #expect(Handoff.standIn.offered == nil)
    }

    @Test func broadwayTakesPagesHandedOverFromAnotherDevice() {
        #expect(Links.instancesRespond(to: #selector(NSApplicationDelegate.application(_:continue:restorationHandler:))))
        #expect(Links.instancesRespond(to: #selector(NSApplicationDelegate.application(_:willContinueUserActivityWithType:))))
    }

    @Test("a page handed over from another device is opened only when it is on the web", arguments: [
        ("https://garden.example/roses", true), ("http://garden.example/", true), ("file:///pages/garden.html", false),
        ("javascript:alert(1)", false),
    ])
    func continued(address: String, opened: Bool) {
        #expect((Handoff.continued(URL(string: address)) != nil) == opened)
    }
}
