import AppKit
import Testing
@testable import Search

private final class SpyFaces: FaceSource, @unchecked Sendable {
    let name: String
    var ready: Bool
    var faces: [String: Data]
    private let lock = NSLock()
    private var calls: [String] = []

    init(_ name: String, ready: Bool = true, faces: [String: Data] = [:]) {
        self.name = name
        self.ready = ready
        self.faces = faces
    }

    var asked: [String] { lock.withLock { calls } }

    func photo(for email: String) -> Data? {
        lock.withLock { calls.append(email) }
        return faces[email]
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MeetingFacesTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("faces-\(UUID().uuidString)")

    private static func png(_ colour: NSColor, side: Int = 200) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func sourcesAreAskedInOrderAndTheFirstPhotoWins() async {
        let contacts = SpyFaces("contacts", faces: ["dana@example.test": Self.png(.red)])
        let later = SpyFaces("later", faces: ["dana@example.test": Self.png(.blue), "fox@example.test": Self.png(.green)])
        let faces = MeetingFaces(sources: [contacts, later], folder: folder)

        let dana = await faces.photo(for: "Dana@Example.test")
        let fox = await faces.photo(for: "fox@example.test")

        #expect(dana != nil)
        #expect(fox != nil)
        #expect(contacts.asked == ["dana@example.test", "fox@example.test"])
        #expect(later.asked == ["fox@example.test"])
    }

    @Test func noPhotoAnywhereFallsBackToInitials() async {
        let contacts = SpyFaces("contacts")
        let faces = MeetingFaces(sources: [contacts], folder: folder)
        let person = MeetingPerson(name: "Walter Skinner", email: "walter@example.test")

        let found = await faces.photo(for: person.email)
        let view = MeetingFaceView(person: person)
        view.show(faces.face(for: person) { _ in Issue.record("no photo should arrive") }, fading: false)

        #expect(found == nil)
        #expect(!view.showsPhoto)
        #expect(MeetingAlertRules.initials(person) == "WS")
        #expect(contacts.asked == ["walter@example.test"])
    }

    @Test func aPhotoShowsInTheCircleInsteadOfTheInitials() async {
        let faces = MeetingFaces(sources: [SpyFaces("contacts", faces: ["dana@example.test": Self.png(.red)])], folder: folder)
        let person = MeetingPerson(name: "Dana Scully", email: "dana@example.test")
        _ = await faces.photo(for: person.email)
        let view = MeetingFaceView(person: person)
        view.addSubview(NSTextField(labelWithString: "DS"))

        view.show(faces.face(for: person) { _ in }, fading: false)

        #expect(view.showsPhoto)
        #expect(view.subviews.allSatisfy { $0.isHidden })
    }

    @Test func aCachedFaceIsNotLookedUpAgain() async {
        let contacts = SpyFaces("contacts", faces: ["dana@example.test": Self.png(.red)])
        let faces = MeetingFaces(sources: [contacts], folder: folder)
        _ = await faces.photo(for: "dana@example.test")
        _ = await faces.photo(for: "nobody@example.test")

        let again = await faces.photo(for: "dana@example.test")
        let missAgain = await faces.photo(for: "nobody@example.test")
        let fresh = MeetingFaces(sources: [contacts], folder: folder)
        let fromDisk = await fresh.photo(for: "dana@example.test")

        #expect(again != nil)
        #expect(missAgain == nil)
        #expect(fromDisk != nil)
        #expect(contacts.asked == ["dana@example.test", "nobody@example.test"])
        #expect(faces.cached("DANA@example.test") != nil)
    }

    @Test func anExpiredFaceIsLookedUpAgain() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let contacts = SpyFaces("contacts", faces: ["dana@example.test": Self.png(.red)])
        let faces = MeetingFaces(sources: [contacts], folder: nil)
        faces.clock = { now }
        _ = await faces.photo(for: "dana@example.test")

        now += MeetingFaces.keep + 1
        _ = await faces.photo(for: "dana@example.test")

        #expect(contacts.asked.count == 2)
    }

    @Test func nothingIsAskedWithoutAReadySource() async {
        let blocked = SpyFaces("contacts", ready: false, faces: ["dana@example.test": Self.png(.red)])
        let none = MeetingFaces(sources: [], folder: folder)
        let shut = MeetingFaces(sources: [blocked], folder: folder)
        let person = MeetingPerson(name: "Dana Scully", email: "dana@example.test")

        let fromNone = await none.photo(for: person.email)
        let fromShut = await shut.photo(for: person.email)
        let shown = shut.face(for: person) { _ in Issue.record("no photo should arrive") }

        #expect(fromNone == nil)
        #expect(fromShut == nil)
        #expect(shown == nil)
        #expect(blocked.asked.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aPersonWithoutAnEmailIsNeverLookedUp() async {
        let contacts = SpyFaces("contacts")
        let faces = MeetingFaces(sources: [contacts], folder: folder)

        let found = await faces.photo(for: "  ")

        #expect(found == nil)
        #expect(contacts.asked.isEmpty)
    }

    @Test func photosAreShrunkToTheCircle() throws {
        let big = Self.png(.red, side: 800)

        let small = try #require(MeetingFaces.shrink(big))
        let image = try #require(NSBitmapImageRep(data: small))

        #expect(image.pixelsWide == MeetingFaces.pixels)
        #expect(image.pixelsHigh == MeetingFaces.pixels)
    }

    @Test func theSharedStoreHasNoSourceOnATestRun() {
        #expect(MeetingFaces.shared.folder == nil)
    }
}
