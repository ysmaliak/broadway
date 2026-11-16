import AppKit
import Testing
@testable import Search

@MainActor
@Suite(.timeLimit(.minutes(5))) struct KitPlateTests {
    @Test func aPagePutsTheTitleContentAndFootInAColumn() {
        let content = NSView()
        let foot = KitButton.pill("Done", font: .systemFont(ofSize: 13), height: 28, padding: 12)
        let page = KitPlatePage("Bookmarks", width: 600, content: content, foot: foot)
        page.frame = NSRect(x: 0, y: 0, width: 760, height: 600)

        page.layoutSubtreeIfNeeded()

        #expect(page.title.frame.minX == 104)
        #expect(page.title.frame.minY == 32)
        #expect(content.frame.minX == 104)
        #expect(content.frame.width == 552)
        #expect(content.frame.minY == 32 + KitPlatePage.titleLine + 16)
        #expect(foot.frame.maxY == 588)
        #expect(content.frame.maxY == foot.frame.minY - 25)
    }

    @Test func aNarrowWindowNarrowsTheColumn() {
        let content = NSView()
        let page = KitPlatePage("Files", width: 600, content: content)
        page.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        page.layoutSubtreeIfNeeded()

        #expect(content.frame.minX == 24)
        #expect(content.frame.width == 352)
        #expect(content.frame.maxY == 300)
    }

    @Test func aPillsTitleIsLaidOutInsideIt() {
        let button = KitButton.pill("New Folder\u{2026}", font: .systemFont(ofSize: 13), height: 28, padding: 12)
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)

        button.layoutSubtreeIfNeeded()

        let label = try? #require(button.content as? KitLabel)
        #expect(label?.superview === button)
        #expect(label?.frame.width ?? 0 > 40)
        #expect(label?.frame.minX == 12)
        #expect(label?.isHidden == false)
        #expect(label?.alphaValue == 1)
        #expect(button.intrinsicContentSize.height == 28)
    }

    @Test func aDestructivePillReadsRed() throws {
        let button = KitButton.pill("Remove", kind: .destructive, font: .systemFont(ofSize: 11.5), height: 22, padding: 9)

        let label = try #require(button.content as? KitLabel)

        #expect(label.color == .systemRed)
        #expect(button.accessibilityLabel() == "Remove")
    }

    @Test func aSearchFieldReportsTypingAndReturn() {
        let field = KitSearchField(prompt: "Search bookmarks")
        var typed: [String] = []
        var submitted = 0
        field.onChange = { typed.append($0) }
        field.onSubmit = { submitted += 1 }

        field.stringValue = "swift"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let handled = field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))

        #expect(typed == ["swift"])
        #expect(handled)
        #expect(submitted == 1)
        #expect(field.placeholderString == "Search bookmarks")
    }
}
