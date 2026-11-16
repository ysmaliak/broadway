import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct SpaceLookPickerTests {
    @Test func thePickerOffersEveryLookAndReportsAPick() throws {
        var picks: [String] = []
        let picker = SpaceLookPicker(picked: "gray") { picks.append($0) }
        picker.frame = NSRect(origin: .zero, size: picker.intrinsicContentSize)
        picker.layoutSubtreeIfNeeded()
        let noir = try #require(picker.tiles.first { $0.offer.id == "noir" })

        let pressed = noir.accessibilityPerformPress()

        #expect(pressed)
        #expect(picks == ["noir"])
        #expect(picker.picked == "noir")
        #expect(picker.look == SpaceLook.offered("noir"))
        #expect(picker.tiles.filter(\.picked).map(\.offer.id) == ["noir"])
        #expect(picker.tiles.map(\.offer) == SpaceLook.offers)
    }

    @Test(arguments: [1, 2, 3, 6])
    func thePickerLaysItsTilesOutInColumnsWithoutOverlap(_ columns: Int) {
        let picker = SpaceLookPicker(picked: "gray", columns: columns) { _ in }

        picker.frame = NSRect(origin: .zero, size: picker.intrinsicContentSize)
        picker.layoutSubtreeIfNeeded()

        let frames = picker.tiles.map(\.frame)
        #expect(frames.allSatisfy { picker.bounds.contains($0) })
        #expect(Set(frames.map(\.minX)).count == min(columns, frames.count))
        for (index, frame) in frames.enumerated() {
            #expect(!frames.dropFirst(index + 1).contains { $0.intersects(frame) })
        }
    }

    @Test func everyTileIsItsMaterialFromEdgeToEdgeAndOnlyGlassHasSomethingBehindIt() throws {
        let picker = SpaceLookPicker(picked: "noir") { _ in }

        picker.frame = NSRect(origin: .zero, size: picker.intrinsicContentSize)
        picker.layoutSubtreeIfNeeded()

        for tile in picker.tiles {
            let ground = try #require(tile.kitSubviews(of: SpaceGroundView.self).first)
            let behind = tile.kitSubviews(of: SpaceLookBackdrop.self)
            #expect(ground.frame.size == tile.bounds.size)
            #expect(ground.glassCorner == SpaceLookTile.corner)
            #expect(behind.isEmpty == !tile.look.showsThrough)
            #expect(behind.allSatisfy { $0.bright && $0.frame.size == tile.bounds.size })
            #expect(tile.glazed == (tile.look.glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency))
        }
        #expect(picker.tiles.filter { $0.look.showsThrough }.map(\.offer.id) == ["glass"])
    }

    @Test func theGlassOnATileHasTheTilesCorners() throws {
        let glass = try #require(SpaceLook.offers.first { $0.id == "glass" })
        let tile = SpaceLookTile(offer: glass, picked: false) {}
        tile.frame = NSRect(origin: .zero, size: SpaceLookPicker.tile)

        tile.layoutSubtreeIfNeeded()

        let panes = tile.kitSubviews(of: NSGlassEffectView.self)
        #expect(panes.count == (tile.glazed ? 1 : 0))
        #expect(panes.allSatisfy { $0.cornerRadius == SpaceLookTile.corner && $0.frame.size == tile.bounds.size })
    }

    @Test func aPickOutsideTheOfferMarksNoTile() {
        let picker = SpaceLookPicker(picked: "noir") { _ in }

        picker.picked = "custom"

        #expect(picker.tiles.filter(\.picked).isEmpty)
        #expect(picker.look == nil)
    }

    @Test func theSmallWindowTakesOnTheLookItIsShown() throws {
        let window = SpaceLookWindow()
        window.frame = NSRect(origin: .zero, size: window.intrinsicContentSize)
        window.layoutSubtreeIfNeeded()
        let noir = try #require(SpaceLook.offered("noir"))

        window.show(noir, animated: false)
        window.layoutSubtreeIfNeeded()

        let ground = try #require(window.kitSubviews(of: SpaceGroundView.self).first)
        #expect(window.look == noir)
        #expect(ground.blend == LookBlend(from: noir))
        #expect(ground.staged)
        #expect(!ground.kitSubviews(of: GrainView.self).isEmpty)
        #expect(window.kitSubviews(of: NSVisualEffectView.self).isEmpty)
    }

    @Test func theChooserKeepsItsWindowAndItsTilesInStepWithoutAnOnboarding() throws {
        var picks: [String] = []
        let worn = SpaceLook(colours: ["123456"], intensity: 0.5, grain: 0.6)
        let chooser = SpaceLookChooser(picked: "custom", custom: worn) { picks.append($0) }
        chooser.frame = NSRect(origin: .zero, size: chooser.intrinsicContentSize)
        chooser.layoutSubtreeIfNeeded()
        let shown = chooser.look
        let glass = try #require(chooser.picker.tiles.first { $0.offer.id == "glass" })

        glass.action()
        let picked = chooser.look
        chooser.show(picked: "custom", animated: false)

        #expect(shown == worn)
        #expect(picks == ["glass"])
        #expect(picked == SpaceLook.offered("glass"))
        #expect(chooser.look == worn)
        #expect(chooser.picker.tiles.filter(\.picked).isEmpty)
        #expect(chooser.bounds.contains(chooser.preview.frame))
        #expect(chooser.bounds.contains(chooser.picker.frame))
        #expect(!chooser.preview.frame.intersects(chooser.picker.frame))
    }
}
