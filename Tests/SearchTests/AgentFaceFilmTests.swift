import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentFaceFilmTests {
    private var folder: URL? {
        ProcessInfo.processInfo.environment["SEARCH_FILM"].map { URL(fileURLWithPath: $0) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder to film the faces into"))
    func filmsEveryMoodAtItsSizes() throws {
        let folder = try #require(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ticks = Int(AgentCharacter.rate * 4.8)
        let moods = AgentCharacter.Mood.allCases.map { mood in
            (mood.title, mood, [AgentCharacter.still(mood)] + frames(mood, ticks))
        }
        let stills = [("Still", AgentCharacter.Mood.idle, AgentCharacter.Mood.allCases.map(AgentCharacter.still))]
        let asking = stride(from: 0, to: ticks, by: 24).map { first in
            ("\(String(format: "%.1f", Double(first) / AgentCharacter.rate)) s", AgentCharacter.Mood.waving, Array(frames(.waving, ticks)[first..<min(ticks, first + 24)]))
        }
        let arrivals = [AgentCharacter.Mood.done, .failed].compactMap { mood in
            AgentCharacter.arrival(from: .typing, to: mood).map { ("\(mood.title) ⇠", mood, [AgentCharacter.still(.typing)] + $0) }
        }
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for side in [CGFloat(14), 18, 22] {
                try sheet(moods, side: side, scale: 2, dark: dark, to: folder.appendingPathComponent("moods-\(Int(side))pt-\(theme).png"))
            }
            for side in [CGFloat(14), 22] {
                try sheet(stills, side: side, scale: 4, dark: dark, to: folder.appendingPathComponent("stills-\(Int(side))pt-\(theme).png"))
                try sheet(asking, side: side, scale: 4, dark: dark, to: folder.appendingPathComponent("needs-you-\(Int(side))pt-\(theme).png"))
            }
            try sheet(arrivals, side: 22, scale: 4, dark: dark, to: folder.appendingPathComponent("arrivals-22pt-\(theme).png"))
        }
    }

    private func frames(_ mood: AgentCharacter.Mood, _ ticks: Int) -> [AgentCharacter.Frame] {
        (0..<ticks).map { AgentCharacter.frame(mood, at: Double($0) / AgentCharacter.rate, seed: 7919) }
    }

    private func sheet(_ rows: [(String, AgentCharacter.Mood, [AgentCharacter.Frame])], side: CGFloat, scale: CGFloat, dark: Bool, to url: URL) throws {
        let cell = side + 8
        let label: CGFloat = 70
        let columns = rows.map(\.2.count).max() ?? 1
        let size = CGSize(width: label + CGFloat(columns) * cell + 8, height: CGFloat(rows.count) * cell + 8)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let cg = context.cgContext
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(NSColor(white: dark ? 0.13 : 0.97, alpha: 1).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        for (row, entry) in rows.enumerated() {
            let y = size.height - 4 - CGFloat(row + 1) * cell
            let words = NSAttributedString(string: entry.0, attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.3, alpha: 1)
            ])
            words.draw(at: CGPoint(x: 6, y: y + cell / 2 - 6))
            for (column, frame) in entry.2.enumerated() {
                let face = AgentCharacterFace(frame: NSRect(x: 0, y: 0, width: side, height: side))
                face.appearance = appearance
                face.seed = 7919
                face.mood = entry.1
                let mood = rows.count == 1 && entry.2.count == AgentCharacter.Mood.allCases.count ? AgentCharacter.Mood.allCases[column] : entry.1
                face.colour = mood == .waving ? Palette.NS.unsafe : AgentCharacter.accentColor(AgentCharacter.Mood.allCases.firstIndex(of: mood) ?? row)
                face.paint(frame)
                let layer = try #require(face.layer)
                cg.saveGState()
                cg.translateBy(x: label + CGFloat(column) * cell + 4, y: y + 4 + side)
                cg.scaleBy(x: 1, y: -1)
                layer.render(in: cg)
                cg.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
