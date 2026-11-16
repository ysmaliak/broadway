import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct FileChoiceTests {
    private func withFiles(_ body: (URL, URL, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("photo.PNG")
        let txt = folder.appendingPathComponent("notes.txt")
        try Data([137, 80, 78, 71]).write(to: png)
        try Data("notes".utf8).write(to: txt)
        try body(folder, png, txt)
    }

    @Test @MainActor func mimeWildcardExtensionsAndUnrestrictedInput() throws {
        try withFiles { _, png, txt in
            let image = FileChoiceRules(accept: "image/*", multiple: false, directories: false)
            let text = FileChoiceRules(accept: "text/plain", multiple: false, directories: false)
            let ext = FileChoiceRules(accept: " .png, application/pdf ", multiple: false, directories: false)
            let any = FileChoiceRules(accept: "", multiple: false, directories: false)

            let accepted = [image.accepts(png), text.accepts(txt), ext.accepts(png), any.accepts(txt)]

            #expect(accepted == [true, true, true, true])
            #expect(!image.accepts(txt))
            #expect(!text.accepts(png))
            #expect(!ext.accepts(txt))
        }
    }

    @Test @MainActor func singleMultipleMissingAndDirectoriesAtCompletion() throws {
        try withFiles { folder, png, txt in
            let single = FileChoiceRules(accept: "", multiple: false, directories: false)
            let multi = FileChoiceRules(accept: "", multiple: true, directories: false)
            let directory = FileChoiceRules(accept: "", multiple: false, directories: true)

            let selected = multi.validated([png, txt, png])
            try FileManager.default.removeItem(at: png)

            #expect(selected == [png, txt])
            #expect(single.validated([png, txt]) == nil)
            #expect(multi.validated([png, txt]) == nil)
            #expect(multi.validated([]) == nil)
            #expect(!single.accepts(folder))
            #expect(directory.validated([folder]) == [folder])
            #expect(!directory.accepts(txt))
        }
    }

    @Test @MainActor func recentFilesAreFilteredDeduplicatedAndNewestFirst() throws {
        try withFiles { _, png, txt in
            let old = Date(timeIntervalSince1970: 100)
            let new = Date(timeIntervalSince1970: 200)
            let rules = FileChoiceRules(accept: "image/*", multiple: false, directories: false)
            let downloads = [Keep(name: png.lastPathComponent, from: "download.test", path: png.path, date: old),
                             Keep(name: txt.lastPathComponent, from: "download.test", path: txt.path, date: new)]
            let uploads = [Upload(name: png.lastPathComponent, site: "upload.test", path: png.path, date: new),
                           Upload(name: "missing.png", site: "upload.test", path: png.path + "missing.png", date: new)]

            let items = rules.recent(downloads: downloads, uploads: uploads, privateDownloads: [], isPrivate: false)

            #expect(items.count == 1)
            #expect(items.first?.source == "upload.test")
        }
    }

    @Test @MainActor func privateWindowOnlyOffersItsOwnDownloads() throws {
        try withFiles { _, png, txt in
            let rules = FileChoiceRules(accept: "", multiple: false, directories: false)
            let ordinary = Keep(name: png.lastPathComponent, from: "ordinary.test", path: png.path, date: Date())
            let privateFile = Keep(name: txt.lastPathComponent, from: "private.test", path: txt.path, date: Date())
            let upload = Upload(name: png.lastPathComponent, site: "upload.test", path: png.path, date: Date())

            let privateItems = rules.recent(downloads: [ordinary], uploads: [upload], privateDownloads: [privateFile], isPrivate: true)
            let ordinaryItems = rules.recent(downloads: [ordinary], uploads: [upload], privateDownloads: [privateFile], isPrivate: false)

            #expect(privateItems.map(\.path) == [txt.path])
            #expect(ordinaryItems.map(\.path) == [png.path])
            #expect(rules.recent(downloads: [ordinary], uploads: [upload], privateDownloads: [], isPrivate: true).isEmpty)
        }
    }

    @MainActor
    @Test func probeTextCheckerOverrideIsProcessLocal() {
        let defaults = UserDefaults.standard
        let domain = UserDefaults.argumentDomain
        let original = defaults.volatileDomain(forName: domain)
        defer { defaults.setVolatileDomain(original, forName: domain) }

        Preferences.tellWebKit(autocorrect: false)
        let off = defaults.volatileDomain(forName: domain)["WebAutomaticSpellingCorrectionEnabled"] as? Bool
        Preferences.tellWebKit(autocorrect: true)
        let on = defaults.volatileDomain(forName: domain)["WebAutomaticSpellingCorrectionEnabled"] as? Bool

        #expect(off == false)
        #expect(on == true)
    }

    @Test func replyCompletesExactlyOnceAndDroppingCancels() async {
        await MainActor.run {
            var replies: [[URL]?] = []
            var pending: FileChoiceReply? = FileChoiceReply { replies.append($0) }
            let file = URL(fileURLWithPath: "/tmp/selected.txt")

            pending?.finish([file])
            pending?.finish(nil)
            pending = nil
            var dropped: FileChoiceReply? = FileChoiceReply { replies.append($0) }
            #expect(dropped != nil)
            dropped = nil
            let cancelled = FileChoiceReply { replies.append($0) }
            cancelled.finish(nil)
            cancelled.finish([file])

            #expect(replies.count == 3)
            #expect(replies[0] == [file])
            #expect(replies[1] == nil)
            #expect(replies[2] == nil)
        }
    }

    @MainActor
    @Test func tabSwitchDuringPreparationCancelsBeforePresentation() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let first = Tab()
        let second = Tab()
        browser.showRow([first, second], active: first.id)
        var answers: [[URL]?] = []
        let reply = FileChoiceReply { answers.append($0) }
        let choice = FileChoice(browser: browser, tab: first, webView: first.web, host: "first.test",
                                rules: FileChoiceRules(accept: "", multiple: false, directories: false), reply: reply)
        browser.fileChoice = choice

        browser.activeID = second.id
        choice.show(at: nil)
        choice.showInFinder()

        #expect(reply.finished)
        #expect(answers.count == 1)
        #expect(answers.compactMap { $0 }.isEmpty)
        #expect(!choice.ready)
        #expect(browser.fileChoice == nil)
    }

    @MainActor
    @Test func switchAwayAndBackDuringPreparationStillCancels() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let first = Tab()
        let second = Tab()
        browser.showRow([first, second], active: first.id)
        var replies = 0
        let reply = FileChoiceReply { _ in replies += 1 }
        let choice = FileChoice(browser: browser, tab: first, webView: first.web, host: "first.test",
                                rules: FileChoiceRules(accept: "", multiple: false, directories: false), reply: reply)
        browser.fileChoice = choice

        browser.activeID = second.id
        browser.activeID = first.id
        let cancelledDuringPreparation = reply.finished
        choice.show(at: nil)
        choice.cancel()

        #expect(cancelledDuringPreparation)
        #expect(reply.finished)
        #expect(replies == 1)
        #expect(!choice.ready)
        #expect(browser.fileChoice == nil)
    }

    @MainActor
    @Test func preparingTheCurrentPeekStillAllowsPresentation() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let peek = Tab()
        browser.peekTab = peek
        let reply = FileChoiceReply { _ in }
        let choice = FileChoice(browser: browser, tab: peek, webView: peek.web, host: "peek.test",
                                rules: FileChoiceRules(accept: "", multiple: false, directories: false), reply: reply)
        browser.fileChoice = choice

        choice.showInFinder()

        #expect(!reply.finished)
        #expect(choice.ready)
        choice.cancel()
        #expect(reply.finished)
    }
}
