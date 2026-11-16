import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsTrailTests {
    @Test func openingADetailKeepsItsPageSelected() {
        var trail = SettingsTrail(page: .privacy)

        trail.open(.liveFolder)

        #expect(trail.page == .liveFolders)
        #expect(trail.detail == .liveFolder)
        #expect(trail.canGoBack)
        #expect(!trail.canGoForward)
    }

    @Test func backFromADetailReturnsToItsPageAndForwardReentersIt() {
        var trail = SettingsTrail(page: .liveFolders)
        trail.open(.liveFolder)

        #expect(trail.back() == true)

        #expect(trail.here == SettingsPlace(page: .liveFolders))
        #expect(trail.canGoForward)
        #expect(trail.forward() == true)
        #expect(trail.detail == .liveFolder)
    }

    @Test func upPopsToTheParentWhenItWasTheLastPlace() {
        var trail = SettingsTrail(page: .liveFolders)
        trail.open(.liveFolder)

        #expect(trail.up() == true)

        #expect(trail.here == SettingsPlace(page: .liveFolders))
        #expect(!trail.canGoBack)
        #expect(trail.canGoForward)
    }

    @Test func upFromADetailReachedFromElsewhereGoesToItsPage() {
        var trail = SettingsTrail(page: .privacy)
        trail.open(.liveFolder)

        #expect(trail.up() == true)

        #expect(trail.here == SettingsPlace(page: .liveFolders))
        #expect(trail.back() == true)
        #expect(trail.detail == .liveFolder)
        #expect(trail.back() == true)
        #expect(trail.here == SettingsPlace(page: .privacy))
    }

    @Test func upOnAPageDoesNothing() {
        var trail = SettingsTrail(page: .liveFolders)

        let moved = trail.up()

        #expect(!moved)
        #expect(trail.here == SettingsPlace(page: .liveFolders))
        #expect(!trail.canGoBack)
    }

    @Test func changingPagesClearsForward() {
        var trail = SettingsTrail(page: .general)
        trail.go(to: .passwords)
        trail.back()
        #expect(trail.canGoForward)

        trail.go(to: .privacy)

        #expect(!trail.canGoForward)
        #expect(trail.behind == [SettingsPlace(page: .general)])
    }

    @Test func theSamePlaceTwiceIsOneStep() {
        var trail = SettingsTrail(page: .general)

        trail.go(to: .general)
        trail.open(.liveFolder)
        trail.open(.liveFolder)

        #expect(trail.behind == [SettingsPlace(page: .general)])
    }

    @Test func detailsAreNamedInAddressesAndOpenedByTheirRow() {
        let names = ["languages", "Language", "livefolder"]

        let found = names.map(SettingsDetail.named)

        #expect(found == [.languages, .languages, .liveFolder])
        #expect(SettingsDetail.named("general") == nil)
        #expect(SettingsDetail.named("routes") == nil)
        #expect(SettingsPage.named("routes") == .links)
        #expect(SettingsPage.named("links") == .links)
        #expect(SettingsDetail.opened(by: "routes") == nil)
        #expect(SettingsDetail.opened(by: "search.shortcuts") == nil)
        #expect(SettingsDetail.opened(by: "privacy.permissions") == nil)
        #expect(SettingsDetail.opened(by: "search.keywords") == nil)
        #expect(SettingsIndex.find("quick").contains { $0.id == "search.quickactions" })
    }

    @Test func everyDetailIsNamedByItsOwnName() {
        let details = SettingsDetail.allCases

        let found = details.map { SettingsDetail.named($0.rawValue) }

        #expect(found == details)
        #expect(SettingsDetail.named("Rule") == .linkRule)
    }

    @Test func noDetailSharesAPageName() {
        let details = SettingsDetail.allCases

        let shared = details.filter { SettingsPage.named($0.rawValue) != nil }

        #expect(shared == [])
    }

    @Test(arguments: [
        ("fieldshortcuts", SettingsPage.field),
        ("quickactions", .field),
        ("quick-actions", .field),
        ("snippets", .field),
        ("keywords", .field),
        ("search", .field),
        ("keyboard", .shortcuts),
        ("keys", .shortcuts),
        ("shortcuts", .shortcuts),
        ("permissions", .websites),
        ("site-permissions", .websites),
    ])
    func oldDrillInNamesOpenTheirPage(name: String, page: SettingsPage) {
        let shell = SettingsShell()
        shell.go(to: .privacy)

        shell.follow(name)

        #expect(SettingsDetail.named(name) == nil)
        #expect(shell.trail.page == page)
        #expect(shell.trail.detail == nil)
    }

    @Test(arguments: ["agents", "Agents", "ai", "mcp"])
    func agentsIsAPageOfItsOwn(name: String) {
        let shell = SettingsShell()
        shell.go(to: .privacy)

        shell.follow(name)

        #expect(SettingsDetail.named(name) == nil)
        #expect(shell.trail.page == .agents)
        #expect(shell.trail.detail == nil)
        #expect(shell.title == "Agents")
    }

    @Test(arguments: ["models", "plans", "providers", "commands", "skills", "routines", "memory", "eye", "watch"])
    func theRemovedSubPagesOpenNothing(name: String) {
        let shell = SettingsShell()
        shell.go(to: .privacy)

        shell.follow(name)

        #expect(SettingsDetail.named(name) == nil)
        #expect(SettingsPage.named(name) == nil)
        #expect(shell.trail.page == .privacy)
        #expect(shell.trail.detail == nil)
    }

    @Test func tabGroupsAreNamedOnTheTabsPage() {
        let names = ["tabgroups", "tab-groups"]

        let found = names.map(SettingsPage.named)

        #expect(found == [.tabs, .tabs])
    }
}
