import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class WelcomeViewTests {
    private var browser: Browser!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
    }

    private func tearDown() async {
        browser.closeAll()
        browser = nil
    }

    @Test func confettiIsTheSameForTheSameSeed() {
        let first = Confetti.pieces(seed: 42)
        let again = Confetti.pieces(seed: 42)
        let other = Confetti.pieces(seed: 43)

        #expect(first.count == Confetti.count)
        #expect(first == again)
        #expect(first != other)
    }

    @Test func aBurstThrowsEveryPieceForTheWholeSecondAndAHalf() throws {
        let host = CALayer()

        let burst = Confetti.throwing(in: host, size: CGSize(width: 800, height: 600), seed: 7)

        let pieces = try #require(burst.sublayers)
        #expect(pieces.count == Confetti.count)
        #expect(pieces.allSatisfy { ($0.animation(forKey: "confetti")?.duration ?? 0) == Confetti.lasts })
        #expect(burst.superlayer === host)
    }

    @Test func confettiStartsLowAndRisesFirst() {
        let size = CGSize(width: 800, height: 600)
        let piece = Confetti.pieces(seed: 1)[0]

        let start = Confetti.spot(piece, at: 0, in: size)
        let soon = Confetti.spot(piece, at: 0.2, in: size)

        #expect(abs(start.y - size.height * 0.95) < 0.001)
        #expect(soon.y < start.y)
    }
}
