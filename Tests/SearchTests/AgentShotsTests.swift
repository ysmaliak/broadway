import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1)))
struct AgentShotsTests {
    private func picture(_ width: Int, _ height: Int, spot: CGRect? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: ShotPixels.space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let spot {
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(spot)
        }
        return context.makeImage()!
    }

    @Test func aShotIsOnePixelForEachPointUnlessAsked() {
        let window = CGSize(width: 1280, height: 800)
        #expect(ShotSize.pixels(points: window, scale: nil, width: nil) == (1280, 800))
        #expect(ShotSize.pixels(points: window, scale: 2, width: nil) == (2560, 1600))
        #expect(ShotSize.pixels(points: window, scale: nil, width: 1024) == (1024, 640))
        #expect(ShotSize.pixels(points: CGSize(width: 1000, height: 333), scale: nil, width: 500) == (500, 167))
        #expect(ShotSize.pixels(points: .zero, scale: nil, width: nil) == (1, 1))
    }

    @Test func anElementGetsAMarginInsideTheView() {
        let view = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(ShotSize.around(CGRect(x: 100, y: 100, width: 50, height: 20), margin: 16, within: view) == CGRect(x: 84, y: 84, width: 82, height: 52))
        #expect(ShotSize.around(CGRect(x: 4, y: 290, width: 50, height: 20), margin: 16, within: view) == CGRect(x: 0, y: 274, width: 70, height: 26))
    }

    @Test func tilesCoverThePageWithASmallOverlap() {
        #expect(ShotSize.tiles(page: 800, view: 800, overlap: 48) == (752, 1))
        #expect(ShotSize.tiles(page: 2000, view: 800, overlap: 48) == (752, 3))
        #expect(ShotSize.tiles(page: 1552, view: 800, overlap: 48) == (752, 2))
        #expect(ShotSize.tiles(page: 1553, view: 800, overlap: 48) == (752, 3))
        #expect(ShotSize.overlap(view: 800) == 80)
        #expect(ShotSize.overlap(view: 300) == 40)
    }

    @Test func askReadsItsFlagsAndNamesMistakes() {
        let plain = ShotAsk.read([:])
        #expect(plain.ask?.scale == nil && plain.ask?.width == nil && plain.ask?.jpeg == false && plain.problem == nil)
        let some = ShotAsk.read(["tiles": true, "from": 3, "count": "4", "format": "jpeg", "quality": 60, "if-changed": true, "marks": "true"])
        #expect(some.ask?.tiles == true && some.ask?.from == 3 && some.ask?.count == 4 && some.ask?.jpeg == true)
        #expect(some.ask?.quality == 0.6 && some.ask?.ifChanged == true && some.ask?.marks == true)
        #expect(ShotAsk.read(["scale": 2, "width": 500]).problem == "Give --scale or --width, not both")
        #expect(ShotAsk.read(["quality": 50]).problem == "--quality goes with --format jpeg")
        #expect(ShotAsk.read(["format": "gif"]).problem == "--format is png or jpeg")
        #expect(ShotAsk.read(["from": 2]).problem == "--from goes with --tiles")
        #expect(ShotAsk.read(["tiles": true, "full": true]).problem == "shot takes one of a target, --full or --tiles")
        #expect(ShotAsk.read(["width": 10]).problem != nil)
        #expect(ShotAsk.read(["scale": 9]).problem != nil)
    }

    @Test func changedCountsThePixelsThatDiffer() {
        let blank = picture(100, 100)
        let spotted = picture(100, 100, spot: CGRect(x: 10, y: 10, width: 10, height: 10))
        #expect(ShotPixels.changed(blank, picture(100, 100)) == 0)
        #expect(ShotPixels.changed(blank, spotted) == 0.01)
        #expect(ShotPixels.changed(blank, picture(50, 100)) == nil)
        #expect(ShotPixels.percent(0.002) == "0.2%")
        #expect(ShotPixels.percent(0.0004) == "under 0.1%")
        #expect(ShotPixels.percent(0) == "0%")
    }

    @Test func picturesAreWrittenAsPNGOrJPEG() throws {
        let image = picture(64, 32, spot: CGRect(x: 0, y: 0, width: 8, height: 8))
        let png = try #require(ShotPixels.encode(image, jpeg: false, quality: 0.8))
        let jpeg = try #require(ShotPixels.encode(image, jpeg: true, quality: 0.5))
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(Array(jpeg.prefix(2)) == [0xFF, 0xD8])
        let back = try #require(NSBitmapImageRep(data: png))
        #expect(back.pixelsWide == 64 && back.pixelsHigh == 32)
    }

    @Test func marksAreDrawnOnThePicture() throws {
        let context = try #require(ShotPixels.canvas(picture(200, 100), width: 200, height: 100))
        ShotMarks.draw([ShotMark(ref: "e12", rect: CGRect(x: 20, y: 20, width: 80, height: 30))], on: context, height: 100)
        let drawn = try #require(context.makeImage())
        let changed = try #require(ShotPixels.changed(picture(200, 100), drawn))
        #expect(changed > 0.01 && changed < 0.3)
    }
}
