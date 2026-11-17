import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct OpenAtLoginTests {
    @Test func aTestRunOnlyEverReachesTheStandIn() {
        #expect(OpenAtLogin.items === OpenAtLogin.standIn)
    }

    @Test func choosingTheRowTurnsItOnThenOff() {
        let items = LoginItemsStandIn()

        let first = OpenAtLogin.change(items)
        let on = items.on
        let second = OpenAtLogin.change(items)

        #expect(first == nil && on)
        #expect(second == nil && !items.on)
    }

    @Test func aRefusalIsToldInTheseWords() {
        let items = LoginItemsStandIn()
        items.refuses = true

        let said = OpenAtLogin.change(items)

        #expect(said == "Couldn't change Open at Login. You can do it in System Settings › General › Login Items.")
        #expect(!items.on)
    }

    @Test func aChangeMacOSDidNotMakeCountsAsARefusal() {
        final class Deaf: LoginItems {
            var on: Bool { false }
            func set(_ on: Bool) throws {}
        }

        #expect(OpenAtLogin.change(Deaf()) == OpenAtLogin.refusal)
    }

    @Test func findASettingFindsIt() {
        let found = SettingsIndex.find("open at login")

        let item = found.first { $0.id == "app.openAtLogin" }
        #expect(item?.title == "Open at login")
        #expect(item?.detail == "In the Broadway menu: Open at Login")
        #expect(item?.findOnly == true)
    }
}
