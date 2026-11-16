import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SnippetPlaceholderTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let english = Locale(identifier: "en_US")

    private func long(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> String {
        let format = DateFormatter()
        format.locale = english
        format.dateStyle = date
        format.timeStyle = time
        return format.string(from: now)
    }

    @Test func dateBecomesTodayInTheLongStyle() {
        let text = "Signed {date}"

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: nil)

        #expect(filled.text == "Signed " + long(.long, .none))
        #expect(filled.tail == "")
    }

    @Test func timeBecomesTheTimeNow() {
        let text = "At {time}."

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: nil)

        #expect(filled.text == "At " + long(.none, .short) + ".")
    }

    @Test func clipboardBecomesTheTextOnTheClipboard() {
        let text = "Ref: {clipboard}!"

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: "A-12")

        #expect(filled.text == "Ref: A-12!")
    }

    @Test func clipboardWithoutTextBecomesNothing() {
        let text = "Ref: {clipboard}!"

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: nil)

        #expect(filled.text == "Ref: !")
    }

    @Test func placeholdersOnTheClipboardAreNotExpandedAgain() {
        let text = "{clipboard} {date}"

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: "{time}{cursor}")

        #expect(filled.text == "{time}{cursor} " + long(.long, .none))
        #expect(filled.tail == "")
    }

    @Test func cursorIsRemovedAndKeepsTheTextAfterIt() {
        let text = "Hi {cursor},\nBest — Ян"

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: nil)

        #expect(filled.text == "Hi ,\nBest — Ян")
        #expect(filled.tail == ",\nBest — Ян")
    }

    @Test func onlyTheFirstCursorMarksTheCaret() {
        let text = "a{cursor}b{cursor}c"

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: nil)

        #expect(filled.text == "abc")
        #expect(filled.tail == "bc")
    }

    @Test func otherBracesStayAsTyped() {
        let text = "{Date} {name} {} {date {{time}} }"

        let filled = Snippet.fill(text, now: now, locale: english, clipboard: "x")

        #expect(filled.text == "{Date} {name} {} {date {" + long(.none, .short) + "} }")
    }

    @Test func theEditorShowsOneLineOfHelpUnderTheText() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-help-\(UUID().uuidString)")
        let store = SnippetStore(url: folder.appendingPathComponent("snippets.json"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
            NSApp.setActivationPolicy(policy)
            try? FileManager.default.removeItem(at: folder)
        }

        SettingsEditors.snippet(Snippet(), store: store, over: window)
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }

        let content = try #require(window.attachedSheet?.contentView)
        let stack = try #require(content.kitSubviews(of: NSStackView.self).first)
        let views = stack.arrangedSubviews
        let box = try #require(views.firstIndex { $0 is NSScrollView })
        let help = views.indices.contains(box + 1) ? views[box + 1] as? NSTextField : nil
        #expect(help?.stringValue == "Use {date}, {time}, {clipboard} and {cursor}")
        if let cancel = content.kitSubviews(of: NSButton.self).first(where: { $0.title == "Cancel" }) { cancel.performClick(nil) }
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SnippetCaretTests {
    private var browser: Browser!
    private var snippet: Snippet!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        let blank = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.showRow([blank], active: blank.id)
        snippet = Snippet(title: "Caret \(UUID().uuidString)", keyword: "c_\(UUID().uuidString)", text: "Hi {cursor}, ref {clipboard}")
        #expect(SnippetStore.shared.save(snippet) == nil)
        AnswerBoard.write("A-12")
    }

    private func tearDown() async {
        SnippetStore.shared.delete(snippet.id)
        AnswerBoard.write("")
        browser.closeAll()
        browser = nil
    }

    private func insert(into page: String, focus: String) async throws -> Tab {
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: page)])
        addTeardownBlock { server.stop() }
        let tab = browser.benchOpen(server.url("/page"))
        browser.select(tab)
        for _ in 0..<300 where tab.loading || tab.committed == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = await PageSelection.run(tab, focus)
        await withCheckedContinuation { done in browser.rememberSnippetSelection { done.resume() } }
        browser.edit()
        browser.typed = ";" + snippet.keyword
        for _ in 0..<200 where browser.leadingSnippet == nil { try await Task.sleep(for: .milliseconds(5)) }
        browser.submit()
        for _ in 0..<200 where browser.announcement != "Inserted snippet" { try await Task.sleep(for: .milliseconds(10)) }
        return tab
    }

    @Test func theCaretLandsAtTheCursorInATextBox() async throws {
        let page = "<!doctype html><textarea>Start </textarea>"
        let focus = "var box = document.querySelector('textarea'); box.focus(); box.setSelectionRange(6, 6); return true;"

        let tab = try await insert(into: page, focus: focus)
        let state = await PageSelection.run(tab, "var box = document.querySelector('textarea'); return [box.value, box.selectionStart, box.selectionEnd];") as? [Any]

        #expect(browser.announcement == "Inserted snippet")
        #expect(state?.first as? String == "Start Hi , ref A-12")
        #expect(state?.dropFirst().first as? Int == 9)
        #expect(state?.last as? Int == 9)
    }

    @Test func theCaretLandsAtTheCursorInAnEditableArea() async throws {
        let page = "<!doctype html><div contenteditable='true'>Start.</div>"
        let focus = """
        var area = document.querySelector('div'); area.focus();
        var range = document.createRange(); range.setStart(area.firstChild, 6); range.collapse(true);
        var picked = getSelection(); picked.removeAllRanges(); picked.addRange(range);
        return true;
        """

        let tab = try await insert(into: page, focus: focus)
        let state = await PageSelection.run(tab, """
        var area = document.querySelector('div'), picked = getSelection();
        var before = document.createRange(); before.setStart(area, 0); before.setEnd(picked.anchorNode, picked.anchorOffset);
        return [area.textContent, before.toString().length, picked.isCollapsed];
        """) as? [Any]

        #expect(browser.announcement == "Inserted snippet")
        #expect((state?.first as? String)?.replacingOccurrences(of: "\u{a0}", with: " ") == "Start.Hi , ref A-12")
        #expect(state?.dropFirst().first as? Int == 9)
        #expect(state?.last as? Bool == true)
    }

    @Test func withoutAnEditorTheCopyHasNoCursorMark() async throws {
        browser.edit()
        browser.typed = ";" + snippet.keyword
        for _ in 0..<200 where browser.leadingSnippet == nil { try await Task.sleep(for: .milliseconds(5)) }

        browser.submit()
        for _ in 0..<100 where browser.editing { try await Task.sleep(for: .milliseconds(5)) }

        #expect(AnswerBoard.written == "Hi , ref A-12")
        #expect(browser.announcement == "Copied snippet")
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SnippetCaretLinesTests {
    private var browser: Browser!
    private var snippet: Snippet!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        let blank = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.showRow([blank], active: blank.id)
        snippet = Snippet(title: "Lines \(UUID().uuidString)", keyword: "l_\(UUID().uuidString)", text: "Hi {cursor},\nBest\nYan")
        #expect(SnippetStore.shared.save(snippet) == nil)
        AnswerBoard.write("")
    }

    private func tearDown() async {
        SnippetStore.shared.delete(snippet.id)
        browser.closeAll()
        browser = nil
    }

    private func insert(into page: String, focus: String) async throws -> Tab {
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: page)])
        addTeardownBlock { server.stop() }
        let tab = browser.benchOpen(server.url("/page"))
        browser.select(tab)
        for _ in 0..<300 where tab.loading || tab.committed == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = await PageSelection.run(tab, focus)
        await withCheckedContinuation { done in browser.rememberSnippetSelection { done.resume() } }
        browser.edit()
        browser.typed = ";" + snippet.keyword
        for _ in 0..<200 where browser.leadingSnippet == nil { try await Task.sleep(for: .milliseconds(5)) }
        browser.submit()
        for _ in 0..<200 where browser.announcement != "Inserted snippet" { try await Task.sleep(for: .milliseconds(10)) }
        return tab
    }

    @Test func theCaretLandsBeforeLaterLinesInATextarea() async throws {
        let page = "<!doctype html><textarea></textarea>"
        let focus = "var box = document.querySelector('textarea'); box.focus(); return true;"

        let tab = try await insert(into: page, focus: focus)
        let state = await PageSelection.run(tab, "var box = document.querySelector('textarea'); return [box.value, box.value.slice(0, box.selectionStart), box.selectionStart === box.selectionEnd];") as? [Any]

        #expect(state?.first as? String == "Hi ,\nBest\nYan")
        #expect(state?.dropFirst().first as? String == "Hi ")
        #expect(state?.last as? Bool == true)
    }

    @Test func theCaretLandsBeforeLaterLinesInAnEditableArea() async throws {
        let page = "<!doctype html><div contenteditable='true'></div>"
        let focus = "var area = document.querySelector('div'); area.focus(); return true;"

        let tab = try await insert(into: page, focus: focus)
        let state = await PageSelection.run(tab, """
        var area = document.querySelector('div'), picked = getSelection();
        var before = document.createRange(); before.setStart(area, 0); before.setEnd(picked.anchorNode, picked.anchorOffset);
        return [area.innerText, before.toString(), picked.isCollapsed];
        """) as? [Any]

        #expect((state?.first as? String)?.replacingOccurrences(of: "\u{a0}", with: " ").hasPrefix("Hi ,\nBest\nYan") == true)
        #expect((state?.dropFirst().first as? String)?.replacingOccurrences(of: "\u{a0}", with: " ") == "Hi ")
        #expect(state?.last as? Bool == true)
    }

    @Test func theCaretLandsAtTheCursorInAOneLineBox() async throws {
        let page = "<!doctype html><input type='text'>"
        let focus = "var box = document.querySelector('input'); box.focus(); return true;"

        let tab = try await insert(into: page, focus: focus)
        let state = await PageSelection.run(tab, "var box = document.querySelector('input'); return [box.value, box.value.slice(0, box.selectionStart)];") as? [Any]

        #expect(browser.announcement == "Inserted snippet")
        #expect((state?.first as? String)?.hasPrefix("Hi ,") == true)
        #expect(state?.last as? String == "Hi ")
    }
}
