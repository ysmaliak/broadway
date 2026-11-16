import AppKit
import Testing
@testable import Search

/// Copy Clean Link's rules on made-up addresses, and the bytes it copies,
/// on a pasteboard of its own rather than the Mac's clipboard (#594).
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CleanLinkTests {
    private func clean(_ text: String) -> String { CleanLink.clean(URL(string: text)!).absoluteString }

    @Test func trackingGoesTheRestStaysInOrder() {
        #expect(clean("https://example.com/article?id=42&utm_source=newsletter#details") == "https://example.com/article?id=42#details")
        #expect(clean("https://example.com/?b=2&utm_medium=x&a=1&fbclid=abc&gclid=1&z=%20y") == "https://example.com/?b=2&a=1&z=%20y")
        #expect(clean("https://example.com/p?UTM_Campaign=Fall&mc_eid=9&igshid=q&msclkid=m") == "https://example.com/p")
        #expect(clean("https://example.com/p?utm_source=a") == "https://example.com/p")
    }

    @Test func nothingToTakeOutLeavesItAlone() {
        for text in ["https://example.com/", "https://example.com/?q=a+b&x=%2F#top",
                     "https://example.com/?si=keep", "file:///Users/me/a.html?utm_source=x",
                     "mailto:a@example.com?subject=utm_source"] {
            #expect(clean(text) == text)
        }
    }

    @Test func shareIdOnlyWhereItTracks() {
        #expect(clean("https://youtu.be/abc?si=XyZ&t=30") == "https://youtu.be/abc?t=30")
        #expect(clean("https://www.youtube.com/watch?v=abc&si=XyZ") == "https://www.youtube.com/watch?v=abc")
        #expect(clean("https://open.spotify.com/track/1?si=abc") == "https://open.spotify.com/track/1")
        #expect(clean("https://notyoutube.com/watch?si=1") == "https://notyoutube.com/watch?si=1")
    }

    @Test func signedAddressesAreCopiedAsTheyAre() {
        let signed = "https://bucket.s3.amazonaws.com/f.pdf?utm_source=x&X-Amz-Signature=abc"
        #expect(clean(signed) == signed)
        let goog = "https://storage.googleapis.com/b/o?X-Goog-Signature=1&utm_medium=y"
        #expect(clean(goog) == goog)
    }

    @MainActor
    @Test func copiedBytesAndWebKitsCopyRewritten() {
        let board = NSPasteboard(name: NSPasteboard.Name("search.cleanlink.test.\(getpid())"))
        defer { board.releaseGlobally() }
        CleanLink.copy(URL(string: "https://example.com/a?x=1&utm_term=t")!, to: board)
        #expect(board.string(forType: .string) == "https://example.com/a?x=1")

        // As WebKit's Copy Link leaves it, written after the menu's action.
        let before = board.changeCount
        board.clearContents()
        board.setString("https://example.com/b?gclid=1&k=v", forType: .URL)
        board.setString("https://example.com/b?gclid=1&k=v", forType: .string)
        CleanLink.rewrite(board, since: before)
        #expect(board.string(forType: .string) == "https://example.com/b?k=v")
    }
}
