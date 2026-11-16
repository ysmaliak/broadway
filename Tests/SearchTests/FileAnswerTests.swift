import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct FileAnswerTests {
    let address = URL(string: "https://files.example/get")!

    func answer(_ type: String?, disposition: String? = nil, status: Int = 200) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let type { headers["Content-Type"] = type }
        if let disposition { headers["Content-Disposition"] = disposition }
        return HTTPURLResponse(url: address, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func anAttachmentIsAFileWhateverItsType() {
        #expect(FileAnswer.attachment(answer("text/html", disposition: "attachment; filename=\"a.html\"")))
        #expect(FileAnswer.attachment(answer("application/pdf", disposition: "  Attachment")))
        #expect(!FileAnswer.attachment(answer("application/pdf", disposition: "inline")))
        #expect(!FileAnswer.attachment(answer("application/pdf")))
        #expect(FileAnswer.navigationIsFile(answer("text/html", disposition: "attachment"), canShow: true))
    }

    @Test func aNavigationIsAFileWhenWebKitCannotShowIt() {
        #expect(FileAnswer.navigationIsFile(answer("application/octet-stream"), canShow: false))
        #expect(!FileAnswer.navigationIsFile(answer("text/html"), canShow: true))
        #expect(!FileAnswer.navigationIsFile(answer("application/pdf"), canShow: true))
    }

    @Test func aRefusedWindowIsKeptOnlyWhenItAnswersWithAFile() {
        #expect(FileAnswer.fetchedIsFile(answer("application/zip")))
        #expect(FileAnswer.fetchedIsFile(answer("application/octet-stream")))
        #expect(FileAnswer.fetchedIsFile(answer("application/pdf")))
        #expect(FileAnswer.fetchedIsFile(answer("text/html", disposition: "attachment; filename=\"page.html\"")))
        #expect(!FileAnswer.fetchedIsFile(answer("text/html")))
        #expect(!FileAnswer.fetchedIsFile(answer("text/html; charset=utf-8")))
        #expect(!FileAnswer.fetchedIsFile(answer("application/xhtml+xml")))
        #expect(!FileAnswer.fetchedIsFile(answer("text/plain")))
        #expect(!FileAnswer.fetchedIsFile(answer("application/zip", status: 404)))
    }

    @Test func anAddressNamesAFileByItsLastPartOrAQueryValue() {
        let named = [
            "https://cdn.example/releases/app-1.2.dmg",
            "https://cdn.example/a/b/Setup.EXE",
            "https://cdn.example/archive.tar.gz?token=abc",
            "https://cdn.example/get?name=report.pdf",
            "https://cdn.example/get?file=folder%2Fnotes.docx",
        ]
        let unnamed = [
            "https://cdn.example/download",
            "https://cdn.example/files/12345",
            "https://cdn.example/page.html",
            "https://cdn.example/ad?campaign=spring",
            "https://cdn.example/.zip",
            "https://cdn.example/v1.2/landing",
        ]
        for text in named { #expect(FileAnswer.namesFile(URL(string: text)), "\(text)") }
        for text in unnamed { #expect(!FileAnswer.namesFile(URL(string: text)), "\(text)") }
        #expect(!FileAnswer.namesFile(nil))
    }
}
