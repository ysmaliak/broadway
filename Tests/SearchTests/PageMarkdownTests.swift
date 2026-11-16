import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PageMarkdownTests {
    private var holding: [AnyObject] = []

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        holding = []
    }

    private func page(_ html: String, at address: String = "https://news.example/2026/story?utm_source=x&id=7") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        let loaded = Loaded()
        holding += [loaded, web]
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: URL(string: address))
        try await loaded.wait()
        return web
    }

    private func copy(_ html: String, title: String = "", at address: String = "https://news.example/2026/story?utm_source=x&id=7") async throws -> String {
        let web = try await page(html, at: address)
        let found = await PageMarkdown.read(web)
        let read = try #require(found)
        return try #require(PageMarkdown.text(title: title, url: URL(string: address), read: read))
    }

    private static let article = """
    <!doctype html><html><head><title>Rivers in Spring | The Example News</title></head><body>
    <nav><a href="/">Home</a> <a href="/world">World</a></nav>
    <div id="cookie-banner" style="position:fixed;bottom:0;left:0;right:0">We use cookies. <button>Accept</button></div>
    <div class="ad">Buy shoes now</div>
    <article>
      <h1>Rivers in Spring</h1>
      <p>Snow melts in <strong>April</strong>, and the rivers <em>rise</em> fast. Read the <a href="/data?utm_source=feed">flow data</a>.</p>
      <h2>What changes <a class="anchor" href="#what">¶</a></h2>
      <p>Banks move a little every year, and the water carries silt for many miles downstream to the sea.</p>
      <figure><img src="/img/river.jpg" alt="A river [in flood]"><figcaption>The river in May.</figcaption></figure>
      <ul><li>Silt</li><li>Stones<ul><li>Small</li><li>Large</li></ul></li></ul>
      <ol start="3"><li>Third</li><li>Fourth</li></ol>
      <blockquote><p>The river is never the same twice.</p></blockquote>
      <p>Use <code>flow_rate</code> to compare years, and keep notes as the season goes on through the summer months.</p>
    </article>
    <footer>© The Example News · <a href="/privacy">Privacy</a></footer>
    </body></html>
    """

    @Test func anArticleBecomesMarkdownWithoutItsClutter() async throws {
        let html = Self.article

        let text = try await copy(html, title: "Rivers in Spring | The Example News")

        #expect(text.hasPrefix("# Rivers in Spring\n\nSource: https://news.example/2026/story?id=7\n\n"), "\(text)")
        #expect(text.contains("Snow melts in **April**, and the rivers *rise* fast. Read the [flow data](https://news.example/data?utm_source=feed)."), "\(text)")
        #expect(text.contains("\n## What changes\n"), "\(text)")
        #expect(text.contains("![A river \\[in flood\\]](https://news.example/img/river.jpg)"), "\(text)")
        #expect(text.contains("- Silt\n- Stones\n  - Small\n  - Large"), "\(text)")
        #expect(text.contains("3. Third\n4. Fourth"), "\(text)")
        #expect(text.contains("> The river is never the same twice."), "\(text)")
        #expect(text.contains("Use `flow_rate` to compare"), "\(text)")
        for clutter in ["Home", "cookies", "Accept", "Buy shoes", "Privacy", "¶"] {
            #expect(!text.contains(clutter), "\(clutter)")
        }
    }

    @Test func docsKeepTheirCodeExactly() async throws {
        let html = """
        <!doctype html><title>Installing</title><main>
        <h1>Installing</h1>
        <p>Run the installer from a terminal, then check that the command answers with its version number.</p>
        <pre><code class="language-swift">let x = 1
        if x > 0 {
            print("``many`` ticks")
        }
        </code></pre>
        <p>That is all there is to it: the command is now on your path and ready for whatever you need it for.</p>
        </main>
        """

        let text = try await copy(html, title: "Installing", at: "https://docs.example/install")

        #expect(text.hasPrefix("# Installing\n\nSource: https://docs.example/install\n\nRun the installer"), "\(text)")
        #expect(text.contains("```swift\nlet x = 1\nif x > 0 {\n    print(\"``many`` ticks\")\n}\n```"), "\(text)")
    }

    @Test func aSimpleTableBecomesAGridAndARaggedOneStaysText() async throws {
        let html = """
        <!doctype html><title>Prices</title><main>
        <p>These are the prices for this year, kept up to date by hand every month by the people who sell them.</p>
        <table><thead><tr><th>Item</th><th>Price</th></tr></thead>
        <tbody><tr><td>Tea</td><td>3 | 4 €</td></tr><tr><td><a href="/coffee">Coffee</a></td><td>5 €</td></tr></tbody></table>
        <table><tr><td colspan="2">Merged heading</td></tr><tr><td>Left</td><td>Right</td></tr></table>
        <p>Prices can change at any time without notice, so check again before you buy anything from the shop.</p>
        </main>
        """

        let text = try await copy(html, title: "Prices", at: "https://shop.example/prices")

        #expect(text.contains("| Item | Price |\n| --- | --- |\n| Tea | 3 \\| 4 € |\n| [Coffee](https://shop.example/coffee) | 5 € |"), "\(text)")
        #expect(text.contains("Merged heading"), "\(text)")
        #expect(text.contains("Left"), "\(text)")
        #expect(!text.contains("| Merged heading"), "\(text)")
    }

    @Test func aSelectionIsCopiedAloneAsMarkdown() async throws {
        let web = try await page(Self.article)
        _ = try await web.evaluateJavaScript("""
        var r = document.createRange();
        var ps = document.querySelectorAll('article p');
        r.setStart(ps[0], 0); r.setEnd(ps[0], ps[0].childNodes.length);
        getSelection().removeAllRanges(); getSelection().addRange(r); 1
        """)

        let found = await PageMarkdown.read(web)
        let read = try #require(found)
        let text = PageMarkdown.text(title: "Rivers", url: URL(string: "https://news.example/"), read: read)

        #expect(read.selected)
        #expect(text == "Snow melts in **April**, and the rivers *rise* fast. Read the [flow data](https://news.example/data?utm_source=feed).")
    }

    @Test func aSelectionInsideCodeStaysCode() async throws {
        let web = try await page("<pre class=\"lang-js\">const a = 1;\nconst b = 2;</pre>")
        _ = try await web.evaluateJavaScript("getSelection().selectAllChildren(document.querySelector('pre')); 1")

        let found = await PageMarkdown.read(web)
        let read = try #require(found)

        #expect(read.markdown == "```js\nconst a = 1;\nconst b = 2;\n```")
    }

    @Test func aSelectionAcrossListItemsKeepsTheList() async throws {
        let web = try await page(Self.article)
        _ = try await web.evaluateJavaScript("""
        var items = document.querySelectorAll('article ul > li');
        var r = document.createRange();
        r.setStart(items[0].firstChild, 0); r.setEnd(items[1].firstChild, 6);
        getSelection().removeAllRanges(); getSelection().addRange(r); 1
        """)

        let found = await PageMarkdown.read(web)
        let read = try #require(found)

        #expect(read.markdown == "- Silt\n- Stones")
    }

    @Test func aSelectionAcrossTableRowsKeepsTheTable() async throws {
        let web = try await page("<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>")
        _ = try await web.evaluateJavaScript("getSelection().selectAllChildren(document.querySelector('tbody')); 1")

        let found = await PageMarkdown.read(web)
        let read = try #require(found)

        #expect(read.markdown == "| A | B |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test func theTitleIsKeptWhenThePageHasNoHeading() {
        let read = PageMarkdown.Read(markdown: "## Part one\n\nWords", selected: false)

        let text = PageMarkdown.text(title: "A Page\nwith a break", url: URL(string: "https://example.com/a#b"), read: read)

        #expect(text == "# A Page with a break\n\nSource: https://example.com/a#b\n\n## Part one\n\nWords")
    }

    @Test func aHeadingUnlikeTheTitleStaysInTheBody() {
        let read = PageMarkdown.Read(markdown: "# Chapter 2\n\nWords", selected: false)

        let text = PageMarkdown.text(title: "My Book", url: nil, read: read)

        #expect(text == "# My Book\n\n# Chapter 2\n\nWords")
    }

    @Test func nothingToCopy() {
        let read = PageMarkdown.Read(markdown: " \n ", selected: false)

        let text = PageMarkdown.text(title: "Empty", url: nil, read: read)

        #expect(text == nil)
    }

    @Test func jsonIsFenced() async throws {
        let web = try await page("<html data-broadway-json><body><pre>{\"a\": 1}</pre></body></html>")

        let found = await PageMarkdown.read(web)
        let read = try #require(found)

        #expect(read.markdown == "```json\n{\"a\": 1}\n```")
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
