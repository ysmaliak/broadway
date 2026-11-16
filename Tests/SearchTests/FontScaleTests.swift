import Foundation
import Testing

@Suite(.timeLimit(.minutes(5)))
struct FontScaleTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func halfPoints() throws -> [String] {
        let context = try Regex(#"ofSize|\.system\(size|Style\(size|pointSize|fontSize|size: CGFloat =|font: CGFloat|NSFont|\bfont\b"#)
        let metric = try Regex(#"ascender|descender|capHeight|xHeight"#)
        let half = try NSRegularExpression(pattern: #"(?<![\d.*/])\b([2-9]|[1-9]\d)\.5\b"#)
        let walker = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        var found: [String] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard text.contains(context), !text.contains(metric),
                      half.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
                found.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        return found.sorted()
    }

    static func baseline() throws -> Int {
        let text = try String(contentsOf: root.appendingPathComponent("Tests/half-point-fonts.txt"), encoding: .utf8)
        return try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func noMoreHalfPointFontSizesThanTheBaseline() throws {
        let allowed = try Self.baseline()

        let found = try Self.halfPoints()

        #expect(found.count <= allowed, "Half-point font sizes: \(found). Use the scale 10, 11, 12, 13, 15, 17, 22, 26, 34.")
    }
}
