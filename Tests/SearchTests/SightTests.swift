import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SightTests {
    private let video = CGRect(x: 100, y: 100, width: 640, height: 360)

    @Test func nothingOverTheVideoCoversNone() {
        let share = Sight.share(of: video, under: [])

        #expect(share == 0)
    }

    @Test func aWindowOverAllOfItCoversAll() {
        let window = video.insetBy(dx: -50, dy: -50)

        let share = Sight.share(of: video, under: [window])

        #expect(share == 1)
    }

    @Test func overlappingWindowsCountOnce() {
        let left = CGRect(x: 100, y: 100, width: 400, height: 360)
        let middle = CGRect(x: 300, y: 100, width: 200, height: 360)

        let share = Sight.share(of: video, under: [left, middle])

        #expect(abs(share - (400.0 / 640.0)) <= 0.05)
    }

    @Test func mostOfItCoveredIsOutOfSightAndAThirdIsNot() {
        let most = CGRect(x: 100, y: 100, width: 640 * 0.8, height: 360)
        let third = CGRect(x: 100, y: 100, width: 640 / 3, height: 360)

        let mostShare = Sight.share(of: video, under: [most])
        let thirdShare = Sight.share(of: video, under: [third])

        #expect(mostShare >= Sight.most)
        #expect(thirdShare < Sight.most)
    }
}
