import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ArcImportTakeTests {
    private func world(_ body: (Browser, LinkRules, String, String) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let previousSpaces = Spaces.read()
        let previousUsesSpaces = browser.prefs.usesSpaces
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arc-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let links = LinkRules(file: folder.appendingPathComponent("links.json"), old: folder.appendingPathComponent("routes.json"))
        let suffix = UUID().uuidString
        let fresh = "Arc Fresh \(suffix)"
        let kept = "Arc Kept \(suffix)"
        defer {
            for space in Spaces.read() where space.name == fresh || space.name == kept {
                Pins.forget(space.id)
                Session.erase(space: space.id)
            }
            Spaces.write(previousSpaces)
            browser.spaces = previousSpaces
            browser.prefs.usesSpaces = previousUsesSpaces
            Disk.drain()
            try? FileManager.default.removeItem(at: folder)
        }
        try body(browser, links, fresh, kept)
    }

    private func sidebar(fresh: String, kept: String) throws -> ArcSidebar {
        let theme: [String: Any] = ["primaryColorPalette": ["midTone": ["red": 0.2, "green": 0.4, "blue": 0.6]]]
        let spaces: [Any] = [
            "FRESH-ID", ["title": fresh, "customInfo": ["windowTheme": theme]],
            "KEPT-ID", ["title": kept, "customInfo": ["windowTheme": theme]],
        ]
        let main: [String: Any] = ["items": [Any](), "spaces": spaces, "topAppsContainerIDs": [Any]()]
        let data = try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [main]]])
        return try #require(Arc.parse(data, profile: nil))
    }

    private var routing: ArcRouting {
        ArcRouting(rules: [.init(kind: .contains, text: "figma.com", space: "fresh-id"),
                           .init(kind: .equals, text: "https://github.com/acme", space: "KEPT-ID"),
                           .init(kind: .contains, text: "a.example", space: "OTHER-ID")], leftOut: 2)
    }

    @Test func aNewSpaceTakesArcsColourAndAnExistingSpaceKeepsItsLook() throws {
        try world { browser, links, fresh, kept in
            let own = SpaceLook(colour: "sage")
            Spaces.write(Spaces.read() + [Space(id: UUID(), name: kept, colour: 0, look: own)])
            browser.spaces = Spaces.read()
            browser.prefs.usesSpaces = true
            browser.takeArc(try sidebar(fresh: fresh, kept: kept), links: links)
            let made = try #require(Spaces.read().first { $0.name == fresh })
            #expect(made.look == SpaceLook(colours: ["336699"], intensity: SpaceLook.bold))
            #expect(Spaces.read().first { $0.name == kept }?.look == own)
        }
    }

    @Test func arcsRulesArriveOnceAndASecondImportAddsNothing() throws {
        try world { browser, links, fresh, kept in
            browser.prefs.usesSpaces = true
            let arc = try sidebar(fresh: fresh, kept: kept)
            let first = browser.takeArc(arc, routing: routing, links: links)
            let freshID = try #require(Spaces.read().first { $0.name == fresh }?.id)
            let keptID = try #require(Spaces.read().first { $0.name == kept }?.id)
            #expect(first.rules == 2)
            #expect(first.leftOut == 3)
            #expect(links.rules.map(\.match) == [.site("figma.com"), .contains("github.com/acme")])
            #expect(links.rules.map(\.target) == [.space(freshID, folder: nil), .space(keptID, folder: nil)])
            #expect(links.rules.allSatisfy { $0.from == .otherApps })
            let again = browser.takeArc(arc, routing: routing, links: links)
            #expect(again.rules == 0)
            #expect(links.rules.count == 2)
        }
    }

    @Test func withSpacesOffOneArcSpaceBringsNoRules() throws {
        try world { browser, links, fresh, _ in
            browser.prefs.usesSpaces = false
            let main: [String: Any] = ["items": [Any](), "spaces": ["FRESH-ID", ["title": fresh]], "topAppsContainerIDs": [Any]()]
            let data = try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [main]]])
            let arc = try #require(Arc.parse(data, profile: nil))
            let took = browser.takeArc(arc, routing: routing, links: links)
            #expect(took.spaces == 0)
            #expect(took.rules == 0)
            #expect(took.leftOut == 5)
            #expect(links.rules.isEmpty)
        }
    }
}
