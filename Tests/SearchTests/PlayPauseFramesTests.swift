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
        guard let transport else {
            Issue.record("no transport in the gallery")
            return [:]
        }
        return await BenchGlassFrames.record(transport.mark, seconds: 0.8, into: Self.folder(name)) { gallery.chrome.playing = playing }
    }

    @Test(arguments: [true, false])
    func theFloatsPlayKeyDrawsFramesBetweenItsTwoFaces(playing: Bool) async {
        let row = await floatFrames(reduced: false, to: playing, name: "float-to-\(playing ? "pause" : "play")")

        #expect(row["ends"] as? Double ?? 0 > 0.004)
        #expect(row["between"] as? Int ?? 0 >= 4, "\(row["between"] ?? "none") frames between")
    }

    @Test func withReducedMotionTheFloatsPlayKeySwapsWithNothingBetween() async {
        let row = await floatFrames(reduced: true, to: false, name: "float-reduced")

        #expect(row["ends"] as? Double ?? 0 > 0.004)
        #expect(row["between"] as? Int == 0)
    }

    @Test func theSidebarPlayKeyDrawsFramesBetweenItsTwoGlyphs() async {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let gallery = GlassKeyGallery(dark: true)
        defer { gallery.close() }
        let toggle = MiniToggle {}
        toggle.frame = NSRect(x: 20, y: 20, width: MiniPlayerView.key, height: MiniPlayerView.key)
        gallery.window.contentView?.addSubview(toggle)
        toggle.show(playing: true)
        toggle.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(800))
        guard let glyph = toggle.kitSubviews(of: MiniGlyph.self).first else { Issue.record("no glyph"); return }

        let row = await BenchGlassFrames.record(glyph, seconds: 0.8, into: Self.folder("sidebar-to-play")) { toggle.show(playing: false) }

        #expect(row["ends"] as? Double ?? 0 > 0.004)
        #expect(row["between"] as? Int ?? 0 >= 4, "\(row["between"] ?? "none") frames between")
    }
}
