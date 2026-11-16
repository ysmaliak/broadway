import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ImageTextTests {
    private func png(_ lines: [String], width: Int = 1600, height: Int = 500) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 70, y: height - 130 - index * 100),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black])
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func englishLinesInReadingOrder() async throws {
        let lines = ["First ticket screenshot", "Second line of text", "Last line here"]
        let image = try png(lines)

        let recognized = try await ImageText().recognize(image)

        #expect(recognized == lines)
    }

    @Test func russianLinesInReadingOrder() async throws {
        let lines = ["Первая строка текста", "Вторая строка текста", "Последняя строка"]
        let image = try png(lines)

        let recognized = try await ImageText().recognize(image)

        #expect(recognized == lines)
    }

    @Test func bothLanguagesOnOneScreenshot() async throws {
        let lines = ["Ticket screenshot", "Проверка русского текста"]
        let image = try png(lines)

        let recognized = try await ImageText().recognize(image)

        #expect(recognized == lines)
    }

    @Test func blankImageHasNoLines() async throws {
        let image = try png([])

        let recognized = try await ImageText().recognize(image)

        #expect(recognized.isEmpty)
    }

    @Test func largeImageDownsamplesBeforeRecognition() throws {
        let image = try png(["A large screenshot"], width: 8000, height: 1000)

        let thumbnail = try ImageText.thumbnail(image)

        #expect(thumbnail.width == ImageText.longestEdge)
        #expect(thumbnail.height == 512)
    }

    @Test func invalidDataIsRejected() async {
        let image = Data("not an image".utf8)

        do {
            _ = try await ImageText().recognize(image)
            Issue.record("Invalid bytes were accepted")
        } catch {
            #expect(error is ImageText.Failure)
        }
    }

    @Test func cancelledRecognitionDoesNotStart() async throws {
        let recognition = ImageText()
        let image = try png(["Keep this on the Mac"])
        recognition.cancel()

        do {
            _ = try await recognition.recognize(image)
            Issue.record("Cancelled recognition succeeded")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func puttingAPinAwayCancelsCopyTask() async throws {
        try await checkCopyCancellation { browser, tab in
            browser.pin(tab)
            browser.close(tab)
            browser.unpin(tab)
        }
    }

    @Test func puttingAGroupedTabAwayCancelsCopyTask() async throws {
        try await checkCopyCancellation { browser, tab in
            browser.prefs.usesTabGroups = true
            let group = browser.newFolder(named: "OCR", editing: false, pinned: true)
            addTeardownBlock { if let group { browser.removeTabGroup(group) } }
            tab.groupID = group
            #expect(browser.putsAway(tab))
            browser.closeTab(tab)
        }
    }

    @Test func lastWindowCloseCancelsCopyEvenWhenSleepingIsOff() async throws {
        try await checkCopyCancellation { browser, _ in
            browser.prefs.sleepsTabs = false
            browser.shut = true
            browser.sleepShut(again: false)
        }
    }

    private func checkCopyCancellation(_ close: (Browser, Tab) -> Void) async throws {
        keepSettings("tabs.sleep")
        let browser = Browser(record: WindowRecord())
        let groups = browser.prefs.usesTabGroups
        let sleeping = browser.prefs.sleepsTabs
        defer {
            browser.closeAll()
            browser.prefs.usesTabGroups = groups
            browser.prefs.sleepsTabs = sleeping
        }
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "about:blank#image-text")!, title: "Picture")
        _ = tab.wake()
        browser.showRow([tab], active: tab.id)
        let board = ImageText.board
        board.clearContents()
        board.setString("Keep this", forType: .string)
        browser.announce("Keep this announcement")
        var release: CheckedContinuation<Void, Never>?
        let copy = Task {
            await withCheckedContinuation { release = $0 }
            guard !Task.isCancelled else { return }
            board.setString("Late copy", forType: .string)
            browser.announce("Late announcement")
        }
        tab.imageTextTask = copy
        tab.imageTextToken = UUID()
        while release == nil { await Task.yield() }

        close(browser, tab)
        release?.resume()
        await copy.value

        #expect(copy.isCancelled)
        #expect(tab.imageTextTask == nil)
        #expect(tab.imageTextToken == nil)
        #expect(board.string(forType: .string) == "Keep this")
        #expect(browser.announcement != "Late announcement")
    }

    @Test func closingTabCancelsCopyTask() async {
        let tab = Tab()
        let work = Task { try? await Task.sleep(for: .seconds(60)) }
        tab.imageTextTask = Task { await work.value }
        let copy = tab.imageTextTask

        tab.close()
        work.cancel()
        await copy?.value

        #expect(copy?.isCancelled == true)
        #expect(tab.imageTextTask == nil)
    }
}
