import Foundation
import Testing
@testable import Search

/// Pins every space shows (Pins.shared): moving a pin in and out of them,
/// a row's order, and pins.json with and without them. In memory only.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SharedPinsTests {
    private func def(_ letter: String) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/",
               title: letter, name: nil)
    }

    @Test func sharingMovesAPinToTheEndOfTheSharedOnes() {
        let a = def("A"), b = def("B"), m = def("M")
        let moved = Pins.share(a.id, own: [a, b], shared: [m])
        #expect(moved.own == [b])
        #expect(moved.shared == [m, a])
    }

    @Test func unsharingMovesAPinToTheStartOfTheSpacesOwn() {
        let a = def("A"), m = def("M"), n = def("N")
        let moved = Pins.unshare(m.id, own: [a], shared: [m, n])
        #expect(moved.own == [m, a])
        #expect(moved.shared == [n])
    }

    @Test func anUnknownPinChangesNothing() {
        let a = def("A"), m = def("M")
        #expect(Pins.share(UUID(), own: [a], shared: [m]).own == [a])
        #expect(Pins.share(UUID(), own: [a], shared: [m]).shared == [m])
        #expect(Pins.unshare(UUID(), own: [a], shared: [m]).own == [a])
        #expect(Pins.unshare(UUID(), own: [a], shared: [m]).shared == [m])
    }

    @Test func splittingARowKeepsEachListInRowOrder() {
        // A shared pin dragged among the space's own is still a shared one,
        // in the order the shared ones had in the row.
        let a = def("A"), m = def("M"), b = def("B"), n = def("N")
        let parts = Pins.split([a, m, b, n], shared: [m.id, n.id])
        #expect(parts.own == [a, b])
        #expect(parts.shared == [m, n])
    }

    @Test func aRowIsTheSharedPinsThenTheSpacesOwn() {
        let a = def("A"), m = def("M")
        #expect(Pins.row(own: [a], shared: [m], showing: true) == [m, a])
    }

    @Test func withSharedPinsHiddenARowIsTheSpacesOwn() {
        let a = def("A"), m = def("M")
        #expect(Pins.row(own: [a], shared: [m], showing: false) == [a])
    }

    @Test func aRowWithItsSharedPinsSaysWhatTheyAre() {
        let m = def("M"), n = def("N")
        #expect(Pins.sharedToWrite([n, m], showing: true) == [n, m])
    }

    @Test func aRowNotYetGivenTheSharedPinsCannotWipeThem() {
        // The switch just turned on, the row not rebuilt yet: it holds no
        // shared pin, and must not write an empty list over the real one.
        #expect(Pins.sharedToWrite([], showing: true) == nil)
    }

    @Test func withSharedPinsHiddenARowSaysNothingAboutThem() {
        #expect(Pins.sharedToWrite([def("M")], showing: false) == nil)
    }

    @Test func aFileWithSharedPinsReadsBothLists() throws {
        let space = UUID()
        let json = """
        {"\(space.uuidString)": [{"id": "\(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"}],
         "shared": [{"id": "\(UUID().uuidString)", "letter": "M", "home": "https://m.example/", "title": "M"}]}
        """
        let read = try #require(Pins.decode(Data(json.utf8)))
        #expect(read.bySpace[space]?.map(\.letter) == ["A"])
        #expect(read.shared.map(\.letter) == ["M"])
        #expect(read.bySpace.count == 1)
    }

    @Test func aFileFromBeforeHasNoSharedPins() throws {
        let space = UUID()
        let json = #"{"\#(space.uuidString)": [{"id": "\#(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"}]}"#
        let read = try #require(Pins.decode(Data(json.utf8)))
        #expect(read.shared == [])
        #expect(read.bySpace[space]?.count == 1)
    }

    @Test func writingAndReadingBackKeepsBothLists() throws {
        let space = UUID(), a = def("A"), m = def("M")
        let data = try #require(Pins.encode(bySpace: [space: [a]], shared: [m]))
        let read = try #require(Pins.decode(data))
        #expect(read.bySpace[space] == [a])
        #expect(read.shared == [m])
    }

    @Test func noSharedPinsWritesNoSharedKey() throws {
        // Someone who never turns the switch on keeps the file they had.
        let data = try #require(Pins.encode(bySpace: [UUID(): [def("A")]], shared: []))
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains("shared"))
    }
}
