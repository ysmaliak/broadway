import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct StagePictureEdgeTests {
    private func picture(_ size: NSSize) -> (StagePicture, NSImage) {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let picture = StagePicture()
        picture.frame = NSRect(origin: .zero, size: size)
        return (picture, image)
    }

    @Test func aRidingPictureWearsTheEdgeRoundItsWholeCard() {
        let (picture, image) = picture(NSSize(width: 400, height: 300))
        let ink = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

        picture.show(image, corner: Metrics.pageRadius, edge: ink)

        #expect(!picture.rim.isHidden)
        #expect(picture.rim.frame == picture.bounds)
        #expect(picture.rim.fillColor == ink.cgColor)
        #expect(picture.rim.fillRule == .evenOdd)
        #expect(picture.rim.strokeColor == nil)
        #expect(picture.rim.path?.boundingBoxOfPath == picture.bounds)
        #expect(picture.rim.path?.contains(CGPoint(x: 0.5, y: 150), using: .evenOdd) == true)
        #expect(picture.rim.path?.contains(CGPoint(x: PaneEdge.width + 0.5, y: 150), using: .evenOdd) == false)
        #expect(picture.rim.path?.contains(CGPoint(x: 0.5, y: 0.5), using: .evenOdd) == true)
        #expect(picture.layer?.masksToBounds == true)
        #expect(picture.layer?.cornerRadius == Metrics.pageRadius)
        #expect(picture.layer?.sublayers?.last === picture.rim)
    }

    @Test func aPictureEdgeToEdgeOrWithNoInkOrNoImageHasNoEdge() {
        let (picture, image) = picture(NSSize(width: 400, height: 300))
        picture.show(image, corner: Metrics.pageRadius, edge: .white)

        picture.show(image, corner: 0, edge: .white)
        #expect(picture.rim.isHidden)
        picture.show(image, corner: Metrics.pageRadius, edge: .white)
        #expect(!picture.rim.isHidden)
        picture.show(image, corner: Metrics.pageRadius)
        #expect(picture.rim.isHidden)
        picture.show(image, corner: Metrics.pageRadius, edge: .white)
        picture.show(nil, corner: Metrics.pageRadius, edge: .white)
        #expect(picture.rim.isHidden)
    }
}
