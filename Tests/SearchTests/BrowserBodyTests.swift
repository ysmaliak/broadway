import Foundation
import Testing

@Suite(.timeLimit(.minutes(5)))
struct BrowserBodyTests {
    static let most = 2600

    @Test func browsersClassBodyStaysShortAndItsMethodsLiveInExtensions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Search/Browser.swift"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")

        let opens = try #require(lines.firstIndex { $0.hasPrefix("final class Browser") })
        let closes = try #require(lines[opens...].firstIndex { $0 == "}" })

        #expect(closes - opens <= Self.most, """
        Browser's class body is \(closes - opens) lines; the most is \(Self.most). @Observable is applied to every member \
        of the body, and every compile job that touches Browser pays for its size (2.7 s a job at 7,005 lines, 0.7 s at 2,490). \
        Put new methods and computed properties in `extension Browser`.
        """)
    }
}
