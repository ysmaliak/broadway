import Foundation
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(2)))
@MainActor
struct SiteNotificationStoresTests {
    private final class Note: NSObject {
        @objc let origin: String
        @objc let title = "3 new messages"
        @objc let body = ""
        @objc let tag: String
        @objc let identifier = NSUUID()

        init(origin: String, tag: String) {
            self.origin = origin
            self.tag = tag
        }
    }

    @Test func aWorkerNotificationReplacedByItsTagKeepsOneStoreNotOnePerNotice() {
        let origin = "https://chat.example"
        let key = SiteNotifications.key(origin)
        Store.settings.set(true, forKey: key)
        defer { Store.settings.removeObject(forKey: key) }
        let notifications = SiteNotifications.shared
        let before = notifications.stores.count
        let store = WKWebsiteDataStore.nonPersistent()

        for _ in 0..<3 { notifications.show(store, notification: Note(origin: origin, tag: "inbox")) }

        #expect(notifications.stores.count == before + 1)
        notifications.closed(["search.key": "tag|\(origin)|inbox"])
        #expect(notifications.stores.count == before)
    }
}
