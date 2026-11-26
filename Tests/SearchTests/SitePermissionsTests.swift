import Foundation
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SitePermissionsTests {
    @Test func listsOnlyChoicesForTheOrigin() {
        let defaults: [String: Any] = [
            "capture.https://meet.example|1": true,
            "capture.https://meet.example|location": false,
            "capture.https://other.example|0": true,
            "unrelated": true,
        ]

        let entries = SitePermissions.entries(for: "https://meet.example", in: defaults)

        #expect(entries.map(\.name) == ["Microphone", "Location"])
        #expect(entries.map(\.allowed) == [true, false])
    }

    @Test func noChoicesGivesNothing() {
        let defaults: [String: Any] = ["capture.https://a.example|notifications": "yes"]

        let entries = SitePermissions.entries(for: "https://a.example", in: defaults)

        #expect(entries.isEmpty)
    }

    @Test func everyRememberedAnswerIsListedPerSiteAllowedOrRefusedFromOneSource() {
        let defaults: [String: Any] = [
            "capture.https://meet.example|0": true,
            "capture.https://meet.example|1": false,
            "capture.https://meet.example|location": true,
            "capture.https://news.example|notifications": false,
            "capture.https://lan.example|\(LocalNetwork.kind)": true,
            "unrelated": true,
        ]

        let sites = SitePermissions.all(in: defaults, popups: ["shop.example"])
        let lines = sites.flatMap { site in site.entries.map { "\(SitePermissions.name(site.site)): \(SitePermissions.words($0))" } }

        #expect(lines == [
            "lan.example: Can reach your local network",
            "meet.example: Can use your camera",
            "meet.example: Can't use your microphone",
            "meet.example: Can see where you are",
            "news.example: Can't send notifications",
            "shop.example: Can open pop-ups without a click",
        ])
        let card = SitePermissions.entries(for: URL(string: "https://shop.example/cart"), in: defaults, popups: ["shop.example"])
        #expect(card.map(\.name) == ["Pop-ups"])
        #expect(SitePermissions.question(sites[1].entries[0], name: "meet.example").title == "Remove the camera choice for meet.example?")
    }

    @Test func aPrivateTabListsAndForgetsOnlyItsOwnAnswers() throws {
        let tab = Tab(shy: true, bench: true)
        tab.restore(url: URL(string: "https://private.example/page")!, title: "Private")
        let origin = try #require(LocalNetwork.origin(tab.pageAddress))
        let normal = "capture.\(origin)|0"
        Store.settings.set(true, forKey: normal)
        defer { Store.settings.removeObject(forKey: normal) }
        let prefs = Preferences()
        LocalNetworkGuard.shared.remember(false, origin: origin, tab: tab.id, shy: true)
        defer { LocalNetworkGuard.shared.forget(tab: tab.id) }
        tab.popupSites.insert("private.example")

        let own = SitePermissions.own(tab)

        #expect(own.map(\.name) == ["Local network", "Pop-ups"])
        #expect(own.map(\.allowed) == [false, true])
        for entry in own { SitePermissions.forget(entry, in: tab, prefs: prefs) }
        #expect(SitePermissions.own(tab).isEmpty)
        #expect(tab.popupSites.isEmpty)
        #expect(Store.settings.object(forKey: normal) as? Bool == true)
    }

    @Test func cameraAndMicrophoneAreTwoAnswersAndARequestForBothAsksOnlyForWhatHasNone() {
        let site = "https://call.example"
        func answer(_ type: WKMediaCaptureType, _ kept: [String: Bool]) -> (decision: Bool?, unanswered: [WKMediaCaptureType]) {
            Browser.captureAnswer(type, site: site) { kept[$0] }
        }

        let cameraOnly = answer(.cameraAndMicrophone, ["\(site)|0": true])
        #expect(cameraOnly.decision == nil && cameraOnly.unanswered == [.microphone])
        #expect(answer(.cameraAndMicrophone, ["\(site)|0": true, "\(site)|1": true]).decision == true)
        #expect(answer(.cameraAndMicrophone, ["\(site)|0": true, "\(site)|1": false]).decision == false)
        #expect(answer(.cameraAndMicrophone, [:]).unanswered == [.camera, .microphone])
        #expect(answer(.microphone, ["\(site)|2": true]).decision == true)
        #expect(answer(.microphone, ["\(site)|2": true, "\(site)|1": false]).decision == false)
        #expect(answer(.camera, ["\(site)|1": true]).unanswered == [.camera])
    }

    @Test func forgetChoicesNamesEverythingItForgets() {
        let line = SettingsIndex.item("privacy.forget")?.detail ?? ""
        let asked = SettingsQuestion.siteChoices.detail

        for word in ["Camera", "microphone", "location", "notifications", "network", "video speeds", "floating videos"] {
            #expect(line.contains(word), "\(word)")
        }
        #expect(asked.contains("local network") && asked.contains("floating video"))
    }

    @Test func forgetRemovesTheChoice() throws {
        let suite = "site-permissions-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeTestDefaults(defaults, suite: suite) }
        let key = "capture.https://forget.example|0"
        defaults.set(true, forKey: key)
        let entry = SitePermissions.Entry(key: key, name: "Camera", allowed: true)

        SitePermissions.remove(entry, from: defaults)

        #expect(defaults.object(forKey: key) == nil)
    }
}
