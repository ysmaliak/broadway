import AppKit
import WebKit
import Testing
@testable import Search

/// Settings › General › Suggestions from your search engine (idea 347).
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct EngineSuggestTests {
    /// Shaped like a GitHub token, made up, and put together here so no
    /// secret scanner takes the file for one.
    private let fakeToken = "gh" + "p_" + "0000Fake1111Token2222Shape3333Only44"

    init() {
        keepSetting(Shared.prefs, \.engine, "search.engine")
        keepSetting(Shared.prefs, \.engineSuggests, "search.suggest")
        keepSetting(Shared.prefs, \.keywords, "search.keywords")
        keepSetting(Shared.prefs, \.customEngine, "search.custom")
    }

    // MARK: - what each engine answers

    @Test func openSearchAnswersAreRead() {
        // Google's (client=firefox), with its extra members after the words.
        let google = #"["coffee",["coffee shop","coffee shop nantes","Coffee","coffee pot"],[],{"google:suggestsubtypes":[[512]]}]"#
        #expect(EngineSuggest.parse(Data(google.utf8), asked: "coffee") == ["coffee shop", "coffee shop nantes", "coffee pot"])
        // DuckDuckGo's, Bing's, Ecosia's, Startpage's, Kagi's, Brave's, Qwant's.
        let plain = #"["café",["café","café del mar"," café au lait ","café del mar"]]"#
        #expect(EngineSuggest.parse(Data(plain.utf8), asked: "Café ") == ["café del mar", "café au lait"])
    }

    @Test func answersAreCappedAtSix() {
        let many = #"["a",["a1","a2","a3","a4","a5","a6","a7","a8"]]"#
        #expect(EngineSuggest.parse(Data(many.utf8), asked: "a").count == 6)
    }

    @Test func anythingElseIsNothing() {
        for junk in ["", "null", "{}", #"{"query":"x","suggestions":["y"]}"#, #"["x"]"#, #"["x","y"]"#,
                     #"["x",[1,2,{"a":1}]]"#, "<html>nope</html>", #"["x",["","  ","line\nbreak"]]"#] {
            #expect(EngineSuggest.parse(Data(junk.utf8), asked: "x") == [], "\(junk)")
        }
        let long = String(repeating: "x", count: 300)
        #expect(EngineSuggest.parse(Data(#"["x",["\#(long)"]]"#.utf8), asked: "x") == [])
    }

    @Test func everyEngineButCustomHasAnHTTPSAddress() throws {
        for engine in Engine.allCases {
            guard engine != .custom else {
                #expect(EngineSuggest.endpoint(for: engine) == nil)
                #expect(EngineSuggest.url(for: "coffee", engine: engine) == nil)
                continue
            }
            let url = try #require(EngineSuggest.url(for: "café crème", engine: engine), "\(engine.title)")
            #expect(url.scheme == "https", "\(engine.title)")
            #expect(url.absoluteString.contains("caf%C3%A9%20cr%C3%A8me"), "\(url.absoluteString)")
        }
        #expect(EngineSuggest.url(for: "a&b", engine: .google)?.absoluteString == "https://suggestqueries.google.com/complete/search?client=firefox&q=a%26b")
        #expect(EngineSuggest.url(for: "x y", engine: .qwant)?.absoluteString == "https://api.qwant.com/api/suggest/?q=x%20y&client=opensearch")
    }

    @Test func onlyHTTPSOrATestRunsLoopback() {
        #expect(EngineSuggest.url(for: "a", engine: .google, test: "http://127.0.0.1:9/s?q=%s") != nil)
        #expect(EngineSuggest.url(for: "a", engine: .google, test: "http://localhost:9/s?q=%s") != nil)
        #expect(EngineSuggest.url(for: "a", engine: .google, test: "http://example.com/s?q=%s") == nil)
        #expect(EngineSuggest.url(for: "a", engine: .google, test: "ftp://127.0.0.1/s?q=%s") == nil)
        #expect(EngineSuggest.url(for: "a", engine: .google, test: "file:///tmp/%s") == nil)
    }

    // MARK: - what may leave the Mac

    @Test func plainWordsAreSent() {
        for words in ["coffee", "coffee shop near me", "café crème", "iphone 15 pro", "how to tie a tie",
                      "what is node.js", "c++ tutorial", "東京 天気", "re: meeting notes", "10:30 train"] {
            #expect(EngineSuggest.sendable(words), "\(words)")
        }
    }

    @Test func addressesAreNeverSent() {
        for address in ["https://example.com", "http://x", "example.com", "www.apple.com/mac", "localhost",
                        "localhost:3000", "127.0.0.1", "192.168.1.1:8080", "[::1]:3000", "mailto:me@example.com",
                        "javascript:alert(1)", "about:blank", "data:text/html,x", "file:///etc/hosts",
                        "node.js", "a/b", "foo.bar", "ftp://files", "chrome-extension://abc"] {
            #expect(!EngineSuggest.sendable(address), "\(address)")
        }
    }

    @Test func pathsAreNeverSent() {
        for path in ["/Users/sam/Documents/taxes.pdf", "~/Desktop", "./build.sh", "../secret",
                     "C:\\Users\\x", "src/main.swift"] {
            #expect(!EngineSuggest.sendable(path), "\(path)")
        }
    }

    @Test func secretsAndPersonalDetailsAreNeverSent() {
        for secret in ["hunter2hunter2x", "sk-proj-4f9aX2kQ7", fakeToken,
                       "AKIAIOSFODNN7EXAMPLE", "correcthorsebatterystaplecorrecthorse",
                       "4111111111111111", "4111-1111-1111-1111", "my password is Tr0ub4dor&3xyzzy",
                       "sam.rowe@example.com", "write to me@example.org", "line one\nline two",
                       String(repeating: "word ", count: 17)] {
            #expect(!EngineSuggest.sendable(secret), "\(secret)")
        }
    }

    @Test func emptyIsNeverSent() {
        for blank in ["", " ", "\n", "\t "] { #expect(!EngineSuggest.sendable(blank)) }
    }

    @Test func aCopyWithNoStoredChoiceSuggestsAndAStoredChoiceIsKept() throws {
        let name = "suggest-default-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }

        #expect(Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: false))
        #expect(!Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: true))

        store.set(false, forKey: "search.suggest")
        #expect(!Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: false))
        #expect(!Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: true))

        store.set(true, forKey: "search.suggest")
        #expect(Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: false))
        #expect(Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: true))
    }

    @Test(.enabled(if: WebRepo.here)) func theRowAndThePrivacyPageSayWhatIsSent() throws {
        let item = try #require(SettingsIndex.item("search.suggest"))
        let page = try String(contentsOf: try #require(WebRepo.site).appendingPathComponent("privacy.html"), encoding: .utf8)

        #expect(item.detail == "What you type is sent to your engine as you type")
        #expect(page.contains("<strong>Search suggestions</strong>"))
        #expect(page.contains("sends what you type to your search engine"))
        #expect(page.contains("Settings › Field"))
    }

    // MARK: - when the field asks

    @Test func theFieldAsksOnlyWhenOnAndNeverInPrivate() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer {
            browser.prefs.engineSuggests = false
            browser.closeAll()
        }
        browser.prefs.engine = .duckduckgo
        browser.prefs.engineSuggests = false
        #expect(browser.engineQuestion(for: "coffee") == nil, "off: nothing asked")

        browser.prefs.engineSuggests = true
        let question = try #require(browser.engineQuestion(for: "coffee"))
        #expect(question.host() == "duckduckgo.com")
        #expect(browser.engineQuestion(for: "example.com") == nil)
        #expect(browser.engineQuestion(for: fakeToken) == nil)

        browser.prefs.engine = .custom
        #expect(browser.engineQuestion(for: "coffee") == nil, "a custom engine has nowhere to ask")
        browser.prefs.engine = .duckduckgo

        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        #expect(quiet.active?.shy == true)
        #expect(quiet.engineQuestion(for: "coffee") == nil, "a private window never asks")
    }

    @Test func aKeywordIsNotAskedAbout() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let kept = browser.prefs.keywords
        defer {
            browser.prefs.keywords = kept
            browser.prefs.engineSuggests = false
            browser.closeAll()
        }
        browser.prefs.engineSuggests = true
        browser.prefs.engine = .google
        browser.prefs.keywords = [Keyword(keyword: "yt", template: "https://www.youtube.com/results?search_query=%s")]
        #expect(browser.engineQuestion(for: "yt cats") == nil, "a shortcut's words go to its site, not the engine")
        #expect(browser.engineQuestion(for: "cats") != nil)
    }

    @Test func recognizedIssueReferencesAreNeverAskedAbout() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer {
            browser.prefs.engineSuggests = false
            browser.closeAll()
        }
        browser.prefs.engineSuggests = true
        browser.prefs.engine = .google

        #expect(browser.issueRef(for: "owner/repo#42") != nil)
        #expect(browser.engineQuestion(for: "owner/repo#42") == nil)
        #expect(browser.engineQuestion(for: "coffee shops") != nil)
    }

    @Test func localAnswersAreNeverAskedAbout() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer {
            browser.prefs.engineSuggests = false
            browser.closeAll()
        }
        browser.prefs.engineSuggests = true
        browser.prefs.engine = .google
        browser.edit()

        for text in ["2+2", "20% of 80", "5 km in mi", "5 км в милях", "255 in hex",
                     "time in tokyo", "время в токио", "15:00 warsaw to new york",
                     "what is the time in tokyo", "what's the time in tokyo", "whats the time in tokyo"] {
            browser.typed = text
            #expect(browser.leadingAnswer != nil, "\(text)")
            #expect(browser.engineQuestion(for: text) == nil, "\(text)")
            browser.picked = browser.offers.firstIndex { $0.kind == .search }
            #expect(browser.engineQuestion(for: text) == nil, "\(text)")
        }
        browser.typed = "weather tomorrow"
        #expect(browser.engineQuestion(for: browser.typed) != nil)
    }
}
