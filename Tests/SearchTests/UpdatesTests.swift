import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct UpdatesTests {
    private let key = "nxl83C8RF5QYop3e8+ObGP7dHn4HZ3NanZmdjG8HPME="
    private let address = "https://broadwaybrowser.com/appcast.xml"

    private var released: [String: Any] { [UpdateFeed.addressKey: address, UpdateFeed.signatureKey: key] }

    @Test func theAutomaticCheckRowSaysTheIntervalReleaseBuildsUse() throws {
        let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build.sh")
        let script = try String(contentsOf: build, encoding: .utf8)

        #expect(script.contains("<key>SUScheduledCheckInterval</key><integer>14400</integer>"))
        #expect(SettingsIndex.item("updates.check")?.detail == "Every four hours, from broadwaybrowser.com")
    }

    @Test func aFeedNeedsItsAddressAndItsKey() {
        let whole = released
        let noKey: [String: Any] = [UpdateFeed.addressKey: address]
        let noAddress: [String: Any] = [UpdateFeed.signatureKey: key]
        let shortKey: [String: Any] = [UpdateFeed.addressKey: address, UpdateFeed.signatureKey: "bm90IGEga2V5"]
        let noHost: [String: Any] = [UpdateFeed.addressKey: "appcast.xml", UpdateFeed.signatureKey: key]

        let read = UpdateFeed.read(whole)

        #expect(read == UpdateFeed(address: URL(string: address)!, key: key))
        #expect(UpdateFeed.read(noKey) == nil)
        #expect(UpdateFeed.read(noAddress) == nil)
        #expect(UpdateFeed.read(shortKey) == nil)
        #expect(UpdateFeed.read(noHost) == nil)
        #expect(UpdateFeed.read([:]) == nil)
    }

    @Test func aReleasedBuildUpdatesOnlyOutsideProbesTestsAndTheBuildFolder() {
        let installed = "/Applications/Broadway.app/Contents/MacOS/Broadway"

        let live = UpdateFeed.live(info: released, probed: false, unitTests: false, executable: installed)
        let probed = UpdateFeed.live(info: released, probed: true, unitTests: false, executable: installed)
        let tested = UpdateFeed.live(info: released, probed: false, unitTests: true, executable: installed)
        let fromBuild = UpdateFeed.live(info: released, probed: false, unitTests: false,
                                        executable: "/work/broadway/.build/out/Products/Release/Search")
        let unreleased = UpdateFeed.live(info: [:], probed: false, unitTests: false, executable: installed)

        #expect(live != nil)
        #expect(probed == nil)
        #expect(tested == nil)
        #expect(fromBuild == nil)
        #expect(unreleased == nil)
    }

    @Test func thisTestRunHasNoUpdater() {
        let updates = Updates.shared

        updates.start()
        updates.check()
        updates.checks = true
        updates.installs = true

        #expect(!Updates.runs)
        #expect(Updates.moveOffer == nil)
        #expect(updates.menuItem() == nil)
        #expect(!updates.canCheck)
        #expect(!updates.checks)
        #expect(!updates.installs)
        #expect(updates.lastChecked == nil)
        #expect(updates.facts["runs"] as? Bool == false)
        #expect(updates.facts["feed"] == nil)
        #expect(updates.line.hasSuffix(UpdateWords.none))
    }

    @Test func aWorldDeclaredInTheBundleIsNamedPlainly() {
        let named: [String: Any] = ["BroadwayWorld": "Update-Run 7!"]

        let world = Store.declared(named)

        #expect(world == "update-run7")
        #expect(Store.declared([:]) == nil)
        #expect(Store.declared(["BroadwayWorld": ""]) == nil)
        #expect(Store.declared(["BroadwayWorld": "test"]) == nil)
        #expect(Store.declared(["BroadwayWorld": 7]) == nil)
        #expect(Store.declaredWorld == nil)
    }

    @Test func aDiskImageOrADownloadedCopyIsAPlaceThatCannotUpdate() {
        let translocated = "/private/var/folders/ab/T/AppTranslocation/1F2E/d/Broadway.app"

        let image = UpdatePlace.found(path: "/Volumes/Broadway/Broadway.app", readOnly: true)
        let download = UpdatePlace.found(path: translocated, readOnly: true)
        let installed = UpdatePlace.found(path: "/Applications/Broadway.app", readOnly: false)

        #expect(image == .diskImage)
        #expect(download == .downloaded)
        #expect(installed == nil)
        #expect(UpdatePlace.diskImage.words.contains("disk image"))
        #expect(UpdatePlace.downloaded.words.contains("Applications"))
    }

    @Test func theVersionLineSaysWhenItLastChecked() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_GB")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 21, minute: 30)))
        let today = now.addingTimeInterval(-3600)
        let yesterday = now.addingTimeInterval(-86400)
        let older = now.addingTimeInterval(-86400 * 9)

        let lines = [nil, today, yesterday, older].map {
            UpdateWords.line(version: "Version 0.1 (1)", runs: true, last: $0, now: now, calendar: calendar)
        }

        #expect(lines[0] == "Version 0.1 (1) · Not checked yet")
        #expect(lines[1] == "Version 0.1 (1) · Last checked today at 20:30")
        #expect(lines[2] == "Version 0.1 (1) · Last checked yesterday at 21:30")
        #expect(lines[3] == "Version 0.1 (1) · Last checked 4 Nov 2026")
        #expect(UpdateWords.line(version: "Version 0.1 (1)", runs: false, last: today) == "Version 0.1 (1) · This build doesn't update itself")
        #expect(UpdateWords.line(version: "Version 0.1 (1)", runs: true, status: UpdateWords.available("0.2"), last: today)
            == "Version 0.1 (1) · Broadway 0.2 is available")
        #expect(UpdateWords.line(version: "Version 0.1 (1)", runs: true, stuck: .diskImage, last: today)
            == "Version 0.1 (1) · Move Broadway to Applications to get updates")
    }

    @Test func theGeneralPageHasTheUpdateRowsAndSaysThisBuildDoesNotUpdate() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .general)
        let view = SettingsPageView(browser: browser, shell: shell)

        view.rebuild()

        let rows = view.kitSubviews(of: SettingsRowView.self)
        let version = try #require(rows.first { $0.rowID == "updates.version" })
        let check = try #require(rows.first { $0.rowID == "updates.check" })
        let install = try #require(rows.first { $0.rowID == "updates.install" })
        let said = version.kitSubviews(of: NSTextField.self).map(\.stringValue)
        #expect(said.contains { $0.hasPrefix("Version ") && $0.hasSuffix(UpdateWords.none) })
        #expect(version.kitSubviews(of: KitButton.self).allSatisfy { !$0.isEnabled })
        for row in [check, install] {
            let toggle = try #require(row.kitSubviews(of: KitSwitch.self).first)
            #expect(!toggle.isOn)
            #expect(!toggle.isEnabled)
            #expect(row.kitSubviews(of: NSTextField.self).contains { $0.stringValue == UpdateWords.none })
        }
        #expect(SettingsIndex.items(in: "updates").map(\.id) == ["updates.version", "updates.check", "updates.install"])
        #expect(SettingsIndex.group("updates")?.page == .general)
    }

    @Test func settingsFindsTheUpdateRows() {
        let typed = ["update", "check for updates", "version", "new version"]

        let found = typed.map { SettingsIndex.find($0).map(\.id) }

        #expect(found[0].contains("updates.check") && found[0].contains("updates.install") && found[0].contains("updates.version"))
        #expect(found[1].contains("updates.check"))
        #expect(found[2].contains("updates.version"))
        #expect(found[3].contains("updates.install"))
    }

    @Test func anAgentCannotTurnUpdatesOff() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let check = try #require(PersonSettings.table["updates.check"])
        let version = try #require(PersonSettings.table["updates.version"])

        let off = ["updates.check", "updates.install"].map { PersonSettings.refusal($0, value: "false") }
        let on = ["updates.check", "updates.install"].map { PersonSettings.refusal($0, value: "true") }

        #expect(off.allSatisfy { $0?.code == "person_only" })
        #expect(on.allSatisfy { $0 == nil })
        #expect(PersonSettings.refusal("updates.version", value: "x")?.code == "refused")
        #expect(check.write?(browser.prefs, "true") == false)
        #expect(check.read(browser.prefs) as? Bool == false)
        #expect((version.read(browser.prefs) as? String)?.hasSuffix(UpdateWords.none) == true)
    }
}
