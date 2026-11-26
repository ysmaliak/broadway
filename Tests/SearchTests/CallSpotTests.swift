import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallSpotTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 340, height: 214)

    private func kept() throws -> KitKeptFrame {
        KitKeptFrame(key: "call.spot", store: try #require(UserDefaults(suiteName: "call-spot-\(UUID().uuidString)")))
    }

    @Test func aPlaceKeptBeforeTheUpdateIsWhereTheCallOpens() throws {
        let kept = try kept()
        kept.store.set([200.0, 150.0], forKey: "call.spot")

        #expect(CallFloat.keptSpot(for: size, kept: kept, on: [screen]) == NSPoint(x: 200, y: 150))
    }

    @Test func anOldPlaceMostlyOffEveryScreenIsNotUsed() throws {
        let kept = try kept()
        kept.store.set([1300.0, 150.0], forKey: "call.spot")

        #expect(CallFloat.keptSpot(for: size, kept: kept, on: [screen]) == nil)
    }

    @Test func theNextPlaceIsWrittenAsAFrameAndReadBackFromIt() throws {
        let kept = try kept()
        kept.store.set([200.0, 150.0], forKey: "call.spot")
        let moved = NSRect(x: 400, y: 300, width: 360, height: 226)

        kept.keep(moved)

        #expect(kept.store.string(forKey: "call.spot") == NSStringFromRect(moved))
        #expect(CallFloat.keptSpot(for: size, kept: kept, on: [screen]) == moved.origin)
    }

    @Test func nothingKeptMeansTheDefaultPlace() throws {
        #expect(CallFloat.keptSpot(for: size, kept: try kept(), on: [screen]) == nil)
    }
}
