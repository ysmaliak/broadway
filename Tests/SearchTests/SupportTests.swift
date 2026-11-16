import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SupportTests {
    private let version = "0.1"
    private let build = "202611140357"
    private let system = "macOS 27.0 (25A123)"
    private let model = "MacBookPro18,3, Apple silicon"

    private func parts(_ url: URL) throws -> (to: String, subject: String, body: String) {
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = parts.queryItems ?? []
        return (parts.path,
                try #require(items.first { $0.name == "subject" }?.value),
                try #require(items.first { $0.name == "body" }?.value))
    }

    private func hands(handler: String?, own: String? = "com.ysmaliak.broadway", log: Box) -> Support.Hands {
        Support.Hands(handler: { _ in handler }, own: own,
                      open: { log.said.append("open \($0.absoluteString)") },
                      copy: { log.said.append("copy \($0)") })
    }

    final class Box {
        var said: [String] = []
    }

    @Test func theMailGoesToSupportWithTheVersionInTheSubject() throws {
        let url = Support.mail(version: version, build: build, system: system, model: model)

        let mail = try parts(url)

        #expect(url.scheme == "mailto")
        #expect(mail.to == "support@broadwaybrowser.com")
        #expect(Support.address == "support@broadwaybrowser.com")
        #expect(mail.subject == "Broadway 0.1 (202611140357)")
    }

    @Test func theBodyIsTwoEmptyLinesAndThreeLinesAboutThisMacAndNothingElse() throws {
        let url = Support.mail(version: version, build: build, system: system, model: model)

        let lines = try parts(url).body.components(separatedBy: "\r\n")

        #expect(lines == ["", "", "Broadway 0.1 (202611140357)", "macOS 27.0 (25A123)", "MacBookPro18,3, Apple silicon"])
    }

    @Test func spacesNewlinesAndPlusesAreEncodedAndComeBackWhole() throws {
        let odd = "0.1+beta&x=1?#"

        let url = Support.mail(version: odd, build: "7 7", system: system, model: model)
        let mail = try parts(url)
        let raw = url.absoluteString

        #expect(mail.subject == "Broadway 0.1+beta&x=1?# (7 7)")
        #expect(mail.body.hasPrefix("\r\n\r\nBroadway 0.1+beta&x=1?# (7 7)\r\n"))
        #expect(raw.hasPrefix("mailto:support@broadwaybrowser.com?subject="))
        #expect(raw.contains("%0D%0A%0D%0ABroadway%200.1%2Bbeta%26x%3D1%3F%23%20(7%207)"))
        #expect(!raw.contains(" ") && !raw.contains("\n") && !raw.contains("+"))
    }

    @Test func thisMacsLinesAreTheShapesTheMailPromises() {
        let system = Support.system
        let model = Support.model

        #expect(system.hasPrefix("macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."))
        #expect(system.hasSuffix(")"))
        #expect(model.hasSuffix(", Apple silicon") || model.hasSuffix(", Intel"))
        #expect(!model.hasPrefix(","))
    }

    @Test func aMailAppGetsTheDraftAndNothingIsCopied() {
        let log = Box()
        var said: [String] = []
        let url = Support.mail(version: version, build: build, system: system, model: model)

        let opened = Support.write(url, hands: hands(handler: "com.apple.mail", log: log)) { said.append($0) }

        #expect(opened)
        #expect(log.said == ["open \(url.absoluteString)"])
        #expect(said.isEmpty)
    }

    @Test func withNoMailAppTheAddressIsCopiedAndSaid() {
        let log = Box()
        var said: [String] = []

        let opened = Support.write(hands: hands(handler: nil, log: log)) { said.append($0) }

        #expect(!opened)
        #expect(log.said == ["copy support@broadwaybrowser.com"])
        #expect(said == ["No mail app is set up. The address is copied."])
    }

    @Test func whenBroadwayItselfWouldTakeTheMailTheAddressIsCopiedInstead() {
        let log = Box()
        var said: [String] = []

        let opened = Support.write(hands: hands(handler: "com.ysmaliak.broadway", own: "com.ysmaliak.broadway", log: log)) { said.append($0) }

        #expect(!opened)
        #expect(log.said == ["copy support@broadwaybrowser.com"])
        #expect(said == [Support.noMail])
    }

    @Test func noWordAPersonReadsHasASemicolon() throws {
        let item = try #require(SettingsIndex.item("support.email"))
        let mail = try parts(Support.mail(version: version, build: build, system: system, model: model))

        let words = [item.title, item.detail, SettingsIndex.group(item.group)?.title ?? "", Support.noMail,
                     "Email Support", "Contact Support", mail.subject, mail.body]

        #expect(words.allSatisfy { !$0.contains(";") })
    }

    @Test func theRowIsOnTheGeneralPageUnderHelpAndFoundByItsWords() throws {
        let typed = ["support", "help", "contact", "email", "feedback", "bug", "report a problem"]

        let found = typed.map { SettingsIndex.find($0).map(\.id) }

        let item = try #require(SettingsIndex.item("support.email"))
        #expect(item.page == .general && item.group == "support" && item.title == "Support")
        #expect(SettingsIndex.group("support")?.title == "Help")
        #expect(SettingsIndex.items(in: "support").map(\.id) == ["support.email"])
        #expect(found.allSatisfy { $0.contains("support.email") }, "\(found)")
        #expect(!SettingsIndex.find("update").map(\.id).contains("support.email"))
        #expect(SettingsStageMap.claim("support.email") == SettingsStageMap.claim("updates.version"))
        #expect(PersonSettings.table["support.email"] != nil)
    }

    @Test func theGeneralPageAndASearchForSupportBothCarryTheButton() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let page = SettingsShell()
        page.go(to: .general)
        let search = SettingsShell()
        search.query = "support"

        let rows = [page, search].map { shell in
            let view = SettingsPageView(browser: browser, shell: shell)
            view.rebuild()
            return view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "support.email" }
        }

        for row in rows {
            let row = try #require(row)
            let pill = try #require(row.kitSubviews(of: SettingsPill.self).first)
            #expect(pill.title == "Email Support")
            #expect(row.detail.stringValue == "Opens an email to support@broadwaybrowser.com with your Broadway and macOS versions")
        }
    }

    @Test func theButtonHandsTheMailOverWithoutOpeningAnythingInATestRun() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.query = "support"
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "support.email" })
        let pill = try #require(row.kitSubviews(of: SettingsPill.self).first)
        Support.handed = []

        #expect(pill.accessibilityPerformPress())

        #expect(Support.handed.count == 1)
        let handed = try #require(Support.handed.first)
        #expect(handed.hasPrefix("open mailto:support@broadwaybrowser.com?subject=Broadway%20") || handed == "copy support@broadwaybrowser.com")
    }

    @Test func helpHasContactSupportAndItDoesTheSameThing() throws {
        _ = NSApplication.shared
        let menu = MenuBar.helpMenu()
        let item = try #require(menu.items.first { $0.title == "Contact Support" } as? MenuCommand)
        Support.handed = []

        item.fire(nil)

        #expect(menu.items.map(\.title) == ["Show Welcome Again", "Contact Support", "", "Broadway on GitHub"])
        #expect(Support.handed.count == 1)
        let handed = try #require(Support.handed.first)
        #expect(handed == "open \(Support.here.absoluteString)" || handed == "copy support@broadwaybrowser.com")
    }

    @Test func helpOpensTheSourceButNeverFromATestWorld() throws {
        _ = NSApplication.shared
        let menu = MenuBar.helpMenu()
        let item = try #require(menu.items.last as? MenuCommand)
        Support.handed = []

        Support.showSource(in: Browser(record: WindowRecord()))

        #expect(item.title == "Broadway on GitHub")
        #expect(Support.source.absoluteString == "https://github.com/ysmaliak/broadway")
        #expect(Support.handed == ["show https://github.com/ysmaliak/broadway"])
    }
}
