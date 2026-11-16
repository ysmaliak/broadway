import Foundation
import Testing
import WebKit
@testable import Search

@Suite
struct PreferredLanguagesTests {
    private let mac = ["en-US", "ru-US"]

    @Test func aTabFollowsSettings() {
        let chosen = ["en-GB", "pl"]

        let list = PreferredLanguages.list(chosen: chosen, mac: mac, space: nil, spaces: true, shy: false)

        #expect(list == ["en-GB", "pl"])
    }

    @Test func aSpaceOverrideWins() {
        let chosen = ["en-GB", "pl"]

        let list = PreferredLanguages.list(chosen: chosen, mac: mac, space: ["de-DE"], spaces: true, shy: false)

        #expect(list == ["de-DE"])
    }

    @Test func aSpaceOverrideWaitsForSpaces() {
        let list = PreferredLanguages.list(chosen: ["en-GB"], mac: mac, space: ["de-DE"], spaces: false, shy: false)

        #expect(list == ["en-GB"])
    }

    @Test func aPrivateWindowFollowsSettings() {
        let list = PreferredLanguages.list(chosen: ["en-GB"], mac: mac, space: ["de-DE"], spaces: true, shy: true)

        #expect(list == ["en-GB"])
    }

    @Test func unsetIsTheMacs() {
        let list = PreferredLanguages.list(chosen: nil, mac: mac, space: nil, spaces: true, shy: false)

        #expect(list == mac)
    }

    @Test func translationGoesIntoTheFirstLanguage() {
        let target = PreferredLanguages.reader(["pl", "en-GB"])

        #expect(target.languageCode?.identifier == "pl")
    }

    @Test func aPageInAnyListedLanguageIsNotOffered() {
        let list = ["en-GB", "pl"]

        #expect(PreferredLanguages.reads(Locale.Language(identifier: "pl"), in: list))
        #expect(PreferredLanguages.reads(Locale.Language(identifier: "en-US"), in: list))
        #expect(!PreferredLanguages.reads(Locale.Language(identifier: "de"), in: list))
    }

    @Test func theSettingsValueNamesTheList() {
        #expect(PreferredLanguages.summary(chosen: ["en-GB", "pl"], mac: mac) == "English, Polish")
        #expect(PreferredLanguages.summary(chosen: ["en", "pl", "de", "fr", "es"], mac: mac) == "English, Polish, German +2")
        #expect(PreferredLanguages.summary(chosen: nil, mac: mac) == "Same as your Mac, English")
    }

    @Test func aSpaceKeepsItsLanguages() throws {
        let space = Space(id: UUID(), name: "Work", colour: 1, languages: ["en-GB", "pl"])

        let read = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))

        #expect(read.languages == ["en-GB", "pl"])
        #expect(read == space)
    }

    @Test func anOlderSpaceHasNoLanguages() throws {
        let saved = #"{"id":"00000000-0000-0000-0000-000000000002","name":"Work","colour":1}"#

        let read = try JSONDecoder().decode(Space.self, from: Data(saved.utf8))

        #expect(read.languages == nil)
        #expect(!String(decoding: try JSONEncoder().encode(read), as: UTF8.self).contains("languages"))
    }

    @Test func theCommandLineTakesAListOrMac() {
        #expect(PreferredLanguages.parse("en-GB, pl") == .some(["en-GB", "pl"]))
        #expect(PreferredLanguages.parse("en_gb,pl,en-GB") == .some(["en-GB", "pl"]))
        #expect(PreferredLanguages.parse("zh-Hant") == .some(["zh-Hant"]))
        #expect(PreferredLanguages.parse("mac") == .some(nil))
        #expect(PreferredLanguages.parse("Mac") == .some(nil))
        #expect(PreferredLanguages.parse("xx") == nil)
        #expect(PreferredLanguages.parse("") == nil)
        #expect(PreferredLanguages.parse("en; drop") == nil)
    }

    @Test @MainActor func aPageGetsAScriptOnlyWhenItsListDiffersFromTheLaunched() {
        #expect(PreferredLanguages.script(for: ["en-GB"], native: ["en-GB"]) == nil)
        #expect(PreferredLanguages.script(for: ["de-DE"], native: ["en-GB"]) != nil)
        #expect(PreferredLanguages.source(["de-DE", "fr"]).contains(#"["de-DE","fr"]"#))
    }

    @Test func addLanguageLeavesListedOnesOut() {
        let offered = PreferredLanguages.choices(leaving: ["pl"], matching: "pol")

        #expect(!offered.contains("pl"))
        #expect(PreferredLanguages.choices(leaving: [], matching: "polish").contains("pl"))
        #expect(PreferredLanguages.choices.contains("en-GB"))
        #expect(PreferredLanguages.choices.contains("pt-BR"))
        #expect(PreferredLanguages.choices.contains("zh-Hant"))
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct PreferredLanguagesPageTests {
    private static let page = """
    <!doctype html><title>languages</title><script>
    fetch('/echo').then(r => r.text()).then(() => { document.title = 'ready' });
    </script>
    """

    @Test func aPageSeesTheListAndASpaceOverrideChangesOnlyWhatItReads() async throws {
        keepSettings("spaces")
        let known = Spaces.known
        let chosen = LanguagePrefs.shared.chosen
        addTeardownBlock {
            Spaces.known = known
            LanguagePrefs.shared.chosen = chosen
            PreferredLanguages.override(nil)
            await Self.restartNetwork()
        }
        let server = try LocalPageServer(["/": .init(type: "text/html", body: Self.page), "/echo": .init(type: "text/plain", body: "ok")])
        defer { server.stop() }
        LanguagePrefs.shared.chosen = ["en-GB"]
        try #require(PreferredLanguages.canOverride)
        let pool = PreferredLanguages.override(["en-GB"])
        await Self.restartNetwork()
        let work = UUID()
        Spaces.known[work] = Space(id: work, name: "Work", colour: 1, languages: ["de-DE", "fr"])
        Store.settings.set(true, forKey: "spaces")

        let plain = try await Self.load(server, space: Space.firstID, pool: pool)
        let header = server.language(asked: "/")
        let fetched = server.language(asked: "/echo")
        let other = try await Self.load(server, space: work, pool: pool)

        #expect(header == "en-GB,en;q=0.9")
        #expect(fetched == "en-GB,en;q=0.9")
        #expect(plain == "en-GB")
        #expect(other == "de-DE,fr")
        #expect(server.language(asked: "/") == "en-GB,en;q=0.9")
    }

    @Test func aChangeShowsWhenAnOpenPageIsReloaded() async throws {
        let chosen = LanguagePrefs.shared.chosen
        let browser = Browser(record: WindowRecord())
        addTeardownBlock {
            LanguagePrefs.shared.chosen = chosen
            browser.closeAll()
        }
        let server = try LocalPageServer(["/": .init(type: "text/html", body: Self.page), "/echo": .init(type: "text/plain", body: "ok")])
        defer { server.stop() }
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(tab)
        browser.showRow([tab], active: tab.id)
        tab.web.load(URLRequest(url: server.url("/")))
        try await Self.ready(tab.web)
        let wanted = PreferredLanguages.native.first == "de-DE" ? ["fr-FR"] : ["de-DE"]

        LanguagePrefs.shared.chosen = wanted
        try await tab.web.evaluateJavaScript("document.title = 'reloading'")
        tab.web.reload()
        try await Self.ready(tab.web)
        let said = try await tab.web.evaluateJavaScript("navigator.languages.join(',')") as? String

        #expect(said == wanted.joined(separator: ","))
    }

    @Test func aSpacesLanguagesPageShowsSameAsSettingsThenItsOwnList() throws {
        let browser = Browser(record: WindowRecord())
        addTeardownBlock { browser.closeAll() }
        let work = Space(id: UUID(), name: "Work", colour: 1)
        browser.spaces.append(work)
        let shell = SettingsShell()
        let page = SettingsPageView(browser: browser, shell: shell)
        shell.openLanguages(space: work.id)

        page.rebuild()
        let following = page.kitSubviews(of: SettingsRowView.self).map(\.rowID)
        browser.setSpaceLanguages(work.id, to: ["de-DE", "fr"])
        page.rebuild()
        let own = page.kitSubviews(of: SettingsRowView.self).map(\.rowID)

        #expect(following.contains("languages.same"))
        #expect(!following.contains("languages.de-DE"))
        #expect(own.contains("languages.same"))
        #expect(own.contains("languages.de-DE"))
        #expect(own.contains("languages.fr"))
    }

    private static func ready(_ web: WKWebView) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if web.title == "ready" { return }
        }
        Issue.record("the page never said it was ready")
    }

    private static func load(_ server: LocalPageServer, space: UUID, pool: WKProcessPool) async throws -> String {
        let configuration = Web.configuration(space: space)
        configuration.processPool = pool
        let tab = Tab(configuration: configuration)
        tab.space = space
        let web = tab.web
        defer { tab.close() }
        web.load(URLRequest(url: server.url("/")))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if web.title == "ready" { break }
        }
        #expect(web.title == "ready")
        let said = try await web.evaluateJavaScript("navigator.languages.join(',')")
        return said as? String ?? ""
    }

    private static func restartNetwork() async {
        let stop = NSSelectorFromString("_terminateNetworkProcess")
        guard Store.websites.responds(to: stop) else { return }
        _ = Store.websites.perform(stop)
        try? await Task.sleep(for: .milliseconds(500))
    }
}
