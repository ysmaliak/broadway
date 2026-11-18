import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder for the frames, on a Mac whose test process runs animations"))
@MainActor
struct PlayPauseFramesTests {
    static func folder(_ name: String) -> URL? {
        ProcessInfo.processInfo.environment["SEARCH_FILM"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
    }

    func floatFrames(reduced: Bool, to playing: Bool, name: String) async -> [String: Any] {
        Store.settings.set(reduced, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let gallery = GlassKeyGallery(dark: true)
        defer { gallery.close() }
        let transport = gallery.keys.first { $0.name == "float play" }?.view as? FloatTransportView
        gallery.chrome.playing = !playing
        transport?.needsLayout = true
        transport?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(800))
        guard let symbol = transport?.toggle.symbol else {
            Issue.record("no play key in the gallery")
            return [:]
        }
        return await BenchGlassFrames.record(symbol, seconds: 0.8, into: Self.folder(name)) { gallery.chrome.playing = playing }
    }

    func smaller(_ row: [String: Any]) -> (rest: Int, frames: Int, sides: [Int]) {
        let sides = row["sides"] as? [Int] ?? []
        let rest = min(sides.first ?? 0, sides.last ?? 0)
        return (rest, sides.filter { Double($0) <= Double(rest) * 0.6 }.count, sides)
    }

    @Test(arguments: [true, false])
    func theFloatsPlayKeyDrawsASmallerMarkBetweenItsTwoGlyphs(playing: Bool) async {
        let row = await floatFrames(reduced: false, to: playing, name: "float-to-\(playing ? "pause" : "play")")
        let found = smaller(row)

        #expect(row["ends"] as? Double ?? 0 > 0.004)
        #expect(found.rest > 0 && found.frames >= 2, "the mark is never smaller between its two glyphs: \(found.sides)")
    }

    @Test func withReducedMotionTheFloatsPlayKeySwapsWithNothingBetween() async {
        let row = await floatFrames(reduced: true, to: false, name: "float-reduced")
        let found = smaller(row)

        #expect(row["ends"] as? Double ?? 0 > 0.004)
        #expect(row["between"] as? Int == 0)
        #expect(found.rest > 0 && found.frames == 0, "\(found.sides)")
    }

    @Test func theSidebarPlayKeyDrawsASmallerMarkBetweenItsTwoGlyphs() async {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let gallery = GlassKeyGallery(dark: false)
        defer { gallery.close() }
        let toggle = MiniToggle {}
        toggle.frame = NSRect(x: 20, y: 20, width: MiniPlayerView.key, height: MiniPlayerView.key)
        gallery.window.contentView?.addSubview(toggle)
        toggle.show(playing: true)
        toggle.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(800))
        guard let glyph = toggle.kitSubviews(of: MiniGlyph.self).first else { Issue.record("no glyph"); return }

        let row = await BenchGlassFrames.record(glyph, seconds: 0.8, into: Self.folder("sidebar-to-play")) { toggle.show(playing: false) }
        let found = smaller(row)

        #expect(row["ends"] as? Double ?? 0 > 0.004)
        #expect(found.rest > 0 && found.frames >= 2, "the mark is never smaller between its two glyphs: \(found.sides)")
    }
}
