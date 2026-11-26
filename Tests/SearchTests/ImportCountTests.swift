import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ImportCountTests {
    @Test func aPlaceBroughtInAgainIsAlreadyHereNotNew() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-count-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = History(file: folder.appendingPathComponent("history.json"), pages: folder.appendingPathComponent("pagetext.sqlite"))
        let page = URL(string: "https://shop.example/cart")!

        let first = history.take(page, title: "Cart", count: 3, last: Date())
        let again = history.take(page, title: "Cart", count: 3, last: Date())
        let local = history.take(URL(string: "file:///tmp/a.html")!, title: "A", count: 1, last: Date())

        #expect(first == true)
        #expect(again == false)
        #expect(local == nil)
    }

    @Test func anyPasswordsFileBroughtInIsNamedWithTheReminderToDeleteIt() {
        let csv = URL(fileURLWithPath: "/tmp/passwords.csv")

        #expect(Browser.inTheClear("12 passwords", file: csv) == "12 passwords. passwords.csv holds your passwords in the clear, so delete it now.")
    }

    @Test func theResultLineSaysWhatIsNewAndWhatWasAlreadyHereAsBookmarksDo() {
        #expect(ImportModel.counted(120, already: 0, "password") == "120 passwords")
        #expect(ImportModel.counted(1, already: 0, "place") == "1 place")
        #expect(ImportModel.counted(0, already: 120, "password") == "0 new passwords, 120 already here")
        #expect(ImportModel.counted(1, already: 2_999, "place") == "1 new place, 2,999 already here")
    }
}
