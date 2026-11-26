import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct CleanLinkTitleTests {
    private let title = NSPasteboard.PasteboardType("public.url-name")

    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("search.cleanlink.title.\(getpid()).\(UUID().uuidString)"))
    }

    @Test func copyCleanLinkKeepsTheLinksTitleAndAddressTypeWithTheCleanAddress() {
        let board = board()
        defer { board.releaseGlobally() }
        let before = board.changeCount
        board.clearContents()
        board.setString("https://shop.example/item?utm_source=mail&k=v", forType: .URL)
        board.setString("Garden chair", forType: title)
        board.setString("https://shop.example/item?utm_source=mail&k=v", forType: .string)

        CleanLink.rewrite(board, since: before)

        #expect(board.string(forType: .URL) == "https://shop.example/item?k=v")
        #expect(board.string(forType: .string) == "https://shop.example/item?k=v")
        #expect(board.string(forType: title) == "Garden chair")
    }

    @Test func copyCleanLinkLeavesNoFormatHoldingTheTrackedAddress() {
        let board = board()
        defer { board.releaseGlobally() }
        let tracked = "https://shop.example/item?utm_source=mail&k=v"
        let before = board.changeCount
        board.clearContents()
        board.setString(tracked, forType: .URL)
        board.setString("Garden chair", forType: title)
        board.setString(tracked, forType: .string)
        board.setString("<a href=\"https://shop.example/item?utm_source=mail&amp;k=v\">Garden chair</a>", forType: .html)
        board.setPropertyList([[tracked], ["Garden chair"]], forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"))

        CleanLink.rewrite(board, since: before)

        let types = board.pasteboardItems?.first?.types ?? []
        #expect(!types.isEmpty)
        for type in types {
            let bytes = board.data(forType: type) ?? Data()
            #expect(!String(decoding: bytes, as: UTF8.self).contains("utm_source"))
        }
        #expect(board.string(forType: title) == "Garden chair")
    }

    @Test func copyCleanLinkLeavesWebKitsCopyAloneWhenNothingNeedsCleaning() {
        let board = board()
        defer { board.releaseGlobally() }
        let before = board.changeCount
        board.clearContents()
        board.setString("https://shop.example/item?k=v", forType: .URL)
        board.setString("Garden chair", forType: title)
        let written = board.changeCount

        CleanLink.rewrite(board, since: before)

        #expect(board.changeCount == written)
        #expect(board.string(forType: title) == "Garden chair")
    }
}
