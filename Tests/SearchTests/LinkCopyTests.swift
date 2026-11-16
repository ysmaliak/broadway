import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LinkCopyTests {
    private func link(_ title: String, _ text: String) -> LinkCopy.Link { LinkCopy.Link(title, URL(string: text)!) }

    @Test func markdownEscapesTitleAndAddress() {
        let tricky = link("A [draft] \\ of\nthings", "https://en.wikipedia.org/wiki/Swift_(programming_language)")

        let text = LinkCopy.markdown([tricky])

        #expect(text == "[A \\[draft\\] \\\\ of things](https://en.wikipedia.org/wiki/Swift_%28programming_language%29)")
    }

    @Test func markdownOnePerLineInOrderWithEmptyTitleFallingBackToHost() {
        let links = [link("One", "https://one.example/a"), link("  ", "https://two.example/b"), link("Three", "https://three.example/")]

        let text = LinkCopy.markdown(links)

        #expect(text == "[One](https://one.example/a)\n[two.example](https://two.example/b)\n[Three](https://three.example/)")
    }

    @Test func htmlEscapesTitleAndHref() {
        let links = [link("Tom & Jerry <\"live\">", "https://example.com/?a=1&b=2"), link("Второй", "https://example.org/")]

        let html = LinkCopy.html(links)

        #expect(html == "<meta charset=\"utf-8\"><a href=\"https://example.com/?a=1&amp;b=2\">Tom &amp; Jerry &lt;&quot;live&quot;&gt;</a><br>\n<a href=\"https://example.org/\">Второй</a>")
    }

    @Test func trackingIsCleanedButSignedAndUnknownStay() {
        let links = [
            link("Video", "https://youtu.be/abc?si=XyZ&t=30"),
            link("Post", "https://example.com/p?id=4&utm_source=x&fbclid=y&gclid=z&ref=keep"),
            link("File", "https://bucket.s3.amazonaws.com/f.pdf?utm_source=x&X-Amz-Signature=abc"),
        ]

        let cleaned = LinkCopy.cleaned(links).map(\.url.absoluteString)

        #expect(cleaned == [
            "https://youtu.be/abc?t=30",
            "https://example.com/p?id=4&ref=keep",
            "https://bucket.s3.amazonaws.com/f.pdf?utm_source=x&X-Amz-Signature=abc",
        ])
    }

    @MainActor
    @Test func richCopyWritesHTMLRTFAndPlainOnItsOwnBoard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("search.linkcopy.test.\(getpid())"))
        defer { board.releaseGlobally() }
        let links = [link("One & Two", "https://one.example/?utm_medium=x&q=1"), link("Three", "https://three.example/")]

        let copied = LinkCopy.copy(links, as: .rich, to: board)

        #expect(copied)
        #expect(board.string(forType: .string) == "https://one.example/?q=1\nhttps://three.example/")
        #expect(board.string(forType: .html) == "<meta charset=\"utf-8\"><a href=\"https://one.example/?q=1\">One &amp; Two</a><br>\n<a href=\"https://three.example/\">Three</a>")
        let rtf = try #require(board.data(forType: .rtf))
        let read = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(read.string == "One & Two\nThree")
        let first = read.attribute(.link, at: 0, effectiveRange: nil)
        #expect(((first as? URL)?.absoluteString ?? (first as? String)) == "https://one.example/?q=1")
    }

    @MainActor
    @Test func markdownAndAddressCopiesAreTextOnly() {
        let board = NSPasteboard(name: NSPasteboard.Name("search.linkcopy.plain.\(getpid())"))
        defer { board.releaseGlobally() }
        let links = [link("One", "https://one.example/?utm_source=x"), link("Two", "https://two.example/")]

        LinkCopy.copy(links, as: .markdown, to: board)

        #expect(board.string(forType: .string) == "[One](https://one.example/)\n[Two](https://two.example/)")
        #expect(board.string(forType: .html) == nil)

        LinkCopy.copy(links, as: .address, to: board)

        #expect(board.string(forType: .string) == "https://one.example/?utm_source=x\nhttps://two.example/")
        #expect(!LinkCopy.copy([], as: .rich, to: board))
    }

    @Test func titlesSayTheCount() {
        #expect(LinkCopy.title(.rich, count: 1) == "Copy as Rich Link")
        #expect(LinkCopy.title(.markdown, count: 3) == "Copy 3 as Markdown Links")
        #expect(LinkCopy.title(.address, count: 2) == "Copy 2 Addresses")
        #expect(LinkCopy.announcement(4, as: .rich) == "4 rich links copied")
    }
}
