import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentReadyTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!

    static let filling = """
    <!doctype html><html lang="en"><title>Report</title><body>
    <script>setTimeout(function () { document.body.insertAdjacentHTML('beforeend', '<h1>Report</h1><p>Totals for the year</p><button>Export</button>'); }, 1500);</script>
    </body></html>
    """
    static let empty = "<!doctype html><html lang=\"en\"><title>Blank</title><body></body></html>"
    static let canvas = """
    <!doctype html><html lang="en"><title>Board</title><body style="margin:0">
    <canvas id="c" width="900" height="700"></canvas>
    <script>var x = document.getElementById('c').getContext('2d'); x.fillStyle = '#c33'; x.fillRect(0, 0, 900, 700);</script>
    </body></html>
    """
    static let framed = """
    <!doctype html><html lang="en"><title>Framed</title><body style="margin:0">
    <script>document.write('<iframe src="http://localhost:' + location.port + '/inner" style="width:100%;height:700px;border:0"></iframe>');</script>
    </body></html>
    """
    static let inner = "<!doctype html><html lang=\"en\"><body><h2>Inner words</h2><p>Kept inside the frame</p></body></html>"
    static let pdf = #"""
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
endobj
4 0 obj
<< /Length 40 >>
stream
BT /F1 18 Tf 40 100 Td (Hello PDF) Tj ET
endstream
endobj
5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000241 00000 n 
0000000331 00000 n 
trailer
<< /Size 6 /Root 1 0 R >>
startxref
401
%%EOF
"""#

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
        server = try LocalPageServer([
            "/filling": .init(type: "text/html", body: Self.filling),
            "/empty": .init(type: "text/html", body: Self.empty),
            "/canvas": .init(type: "text/html", body: Self.canvas),
            "/framed": .init(type: "text/html", body: Self.framed),
            "/inner": .init(type: "text/html", body: Self.inner),
            "/file.pdf": .init(type: "application/pdf", body: Self.pdf),
            "/slow": .init(type: "text/html", body: "<!doctype html><title>Slow</title><p>Late words</p>", hold: 9),
        ])
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        AgentDesk.shared.drop(task: task)
        server?.stop()
        AgentSites.shared.reset()
        browser?.closeAll()
        browser = nil
    }

    private func open(_ path: String, settle: Bool = true) async throws -> String {
        _ = await box.call("open", ["url": server.url(path).absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        if settle { _ = await box.call("wait", ["tab": id], task: task) }
        return id
    }

    @Test func readWaitsForAPageThatIsStillDrawingItself() async throws {
        let id = try await open("/filling", settle: false)

        let read = await box.call("text", ["tab": id], task: task)

        #expect(!read.failed, "\(read.text ?? "")")
        #expect(read.text?.contains("Totals for the year") == true, "\(read.text ?? "")")
    }

    @Test func snapshotWaitsForAPageThatIsStillDrawingItself() async throws {
        let id = try await open("/filling", settle: false)

        let look = await box.call("snapshot", ["tab": id], task: task)

        #expect(!look.failed, "\(look.text ?? "")")
        #expect(look.text?.contains("\"Export\"") == true, "\(look.text ?? "")")
    }

    @Test func anEmptyPageSaysItIsEmpty() async throws {
        let id = try await open("/empty")

        let read = await box.call("text", ["tab": id], task: task)

        #expect(read.failed)
        #expect(read.code == "no_answer")
        #expect(read.text?.contains("empty") == true, "\(read.text ?? "")")
        #expect(read.hint?.contains("broadway wait") == true, "\(read.hint ?? "")")
    }

    @Test func aPageThatIsOnlyAPictureSaysSoAndNamesShot() async throws {
        let id = try await open("/canvas")

        let read = await box.call("text", ["tab": id], task: task)
        let look = await box.call("snapshot", ["tab": id], task: task)
        let shot = await box.call("screenshot", ["tab": id], task: task)

        #expect(read.failed)
        #expect(read.code == "no_answer")
        #expect(read.text?.contains("picture") == true, "\(read.text ?? "")")
        #expect(read.hint?.contains("broadway shot") == true, "\(read.hint ?? "")")
        #expect(look.text?.contains("picture") == true, "\(look.text ?? "")")
        #expect(!shot.failed, "\(shot.text ?? "")")
    }

    @Test func aPageThatIsOneFrameFromAnotherSiteNamesItAndTheCommandThatReadsIt() async throws {
        let id = try await open("/framed")
        try await Task.sleep(for: .milliseconds(500))

        let read = await box.call("text", ["tab": id], task: task)
        let inside = await box.call("snapshot", ["tab": id, "text": true], task: task)

        #expect(read.failed)
        #expect(read.text?.contains("frame from localhost") == true, "\(read.text ?? "")")
        #expect(read.hint?.contains("broadway snapshot --text") == true, "\(read.hint ?? "")")
        #expect(inside.text?.contains("Inner words") == true, "\(inside.text ?? "")")
    }

    @Test func aPDFSaysItIsAPDFAndNamesShot() async throws {
        let id = try await open("/file.pdf")
        try await Task.sleep(for: .milliseconds(500))

        let read = await box.call("text", ["tab": id], task: task)
        let shot = await box.call("screenshot", ["tab": id], task: task)

        #expect(read.failed)
        #expect(read.text?.contains("PDF") == true, "\(read.text ?? "")")
        #expect(read.hint?.contains("broadway shot") == true, "\(read.hint ?? "")")
        #expect(!shot.failed, "\(shot.text ?? "")")
    }

    @Test func aPageStillLoadingAfterTheWaitSaysSo() async throws {
        let id = try await open("/slow", settle: false)

        let read = await box.call("text", ["tab": id], task: task)

        #expect(read.failed)
        #expect(read.text?.contains("still loading") == true, "\(read.text ?? "")")
        #expect(read.hint?.contains("broadway wait") == true, "\(read.hint ?? "")")
    }
}
