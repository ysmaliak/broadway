import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct OldDataTests {
    @Test func theSwitchesOfTheAskLineAndTheTextActionsStayOnDiskUnread() {
        keepSettings("ai.actions", "ai.ask")
        Store.settings.set(false, forKey: "ai.actions")
        Store.settings.set(false, forKey: "ai.ask")

        _ = Preferences()

        #expect(Store.settings.object(forKey: "ai.actions") as? Bool == false)
        #expect(Store.settings.object(forKey: "ai.ask") as? Bool == false)
        #expect(PersonSettings.refusal("ai.actions", value: "true")?.code == "not_found")
        #expect(PersonSettings.refusal("ai.ask", value: "true")?.code == "not_found")
        #expect(SettingsIndex.item("ai.ask") == nil)
    }

    @Test func aKeyKeptForTheChatOrTheAskLineIsSkippedAndTheOthersStay() throws {
        keepSettings("shortcuts")
        let saved = ["view.ask": [String: String](), "view.chat": [:], "edit.text.improve": [:], "tabs.pin": [:]]
        Store.settings.set(try JSONEncoder().encode(saved), forKey: "shortcuts")

        let store = ShortcutStore()

        #expect(store.isChanged("tabs.pin"))
        #expect(!store.isChanged("view.ask"))
        #expect(!store.isChanged("view.chat"))
        #expect(Command.named("view.ask") == nil)
        #expect(Command.named("view.chat") == nil)
    }
}
