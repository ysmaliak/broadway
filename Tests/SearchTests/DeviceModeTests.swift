import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct DeviceModeTests {
    @Test func rotateSwapsTheSides() {
        var state = DeviceState(.standard)
        let width = state.width, height = state.height

        state.rotate()

        #expect(state.width == height)
        #expect(state.height == width)
    }

    @Test func resizeIsCustomAndHasAFloor() {
        var state = DeviceState(.standard)

        state.resize(width: 12.4)

        #expect(state.name == "Custom")
        #expect(state.width == DeviceState.smallest)
    }

    @Test func dragTravelsBothEdgesAndShiftIsFine() {
        let start: CGFloat = 400

        let plain = DeviceState.drag(from: start, by: 10, fine: false)
        let fine = DeviceState.drag(from: start, by: 10, fine: true)

        #expect(plain == 420)
        #expect(fine == 405)
    }

    @Test func frameIsCentredAndNeverLargerThanTheStage() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 700)

        let phone = StageView.deviceFrame(NSSize(width: 400, height: 500), in: bounds)
        let tablet = StageView.deviceFrame(NSSize(width: 800, height: 1200), in: bounds)

        #expect(phone == NSRect(x: 300, y: 100, width: 400, height: 500))
        #expect(tablet == NSRect(x: 100, y: 0, width: 800, height: 700))
    }

    @Test func everyProfileHasAnAgentOfItsKind() {
        let list = DeviceProfile.list

        let phones = list.filter { $0.agent == .iPhone }

        #expect(phones.allSatisfy { $0.agent.text.contains("iPhone") })
        #expect(Set(list.map { $0.name }).count == list.count)
    }
}
