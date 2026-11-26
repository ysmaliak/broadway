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

    @Test func theKeysOfPlansTasksAndRemovedReviewsStayOnDiskUnread() {
        keepSettings("ai.plan", "ai.watch", "ai.routines", "ai.memory")
        Store.settings.set("claude", forKey: "ai.plan")
        Store.settings.set(true, forKey: "ai.watch")
        Store.settings.set(true, forKey: "ai.routines")

        _ = Preferences()

        #expect(Store.settings.string(forKey: "ai.plan") == "claude")
        #expect(Store.settings.object(forKey: "ai.watch") as? Bool == true)
        #expect(Store.settings.object(forKey: "ai.routines") as? Bool == true)
        #expect(PersonSettings.refusal("ai.plan", value: "codex")?.code == "not_found")
        #expect(SettingsIndex.item("ai.plan") == nil)
    }

    @Test func theFilesOfChatsTasksAndRemovedReviewsStayOnDiskUntouched() throws {
        let chats = Store.file("Chats")
        let chat = chats.appendingPathComponent("6f1c2d3e-0000-4000-8000-000000000001.json")
        let files = [chat, Store.file("eye.json"), Store.file("routines.json"), Store.file("get-to-know.json")]
        let words = Data(#"{"title":"Find a flight","kind":"task","steps":[{"tool":"open"}]}"#.utf8)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        for file in files { try words.write(to: file) }
        defer {
            for file in files { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: chats)
        }

        _ = Preferences()
        let browser = Browser(record: WindowRecord())
        browser.closeAll()

        for file in files { #expect(try Data(contentsOf: file) == words, "\(file.lastPathComponent)") }
    }

    @Test func anOutsideAgentsEntryKeepsItsPlace() {
        let link = UUID()
        TaskLedger.shared.open(link, title: "Claude Code")
        defer { TaskLedger.shared.close(link) }

        #expect(TaskLedger.shared.entry(link) == TaskLedger.Entry(title: "Claude Code"))
    }

    @Test func notesAnAgentKeptStayOnDiskUntouchedAndUnread() throws {
        keepSettings("ai.memory")
        Store.settings.set(false, forKey: "ai.memory")
        let folder = Store.file("Memory")
        let you = folder.appendingPathComponent("you", isDirectory: true)
        let note = you.appendingPathComponent("About you.md")
        let words = Data("# About you\n\n- Likes tea\n".utf8)
        let existed = FileManager.default.fileExists(atPath: folder.path)
        try FileManager.default.createDirectory(at: you, withIntermediateDirectories: true)
        try words.write(to: note)
        defer {
            try? FileManager.default.removeItem(at: note)
            if !existed { try? FileManager.default.removeItem(at: folder) }
        }

        _ = Preferences()
        let browser = Browser(record: WindowRecord())
        browser.closeAll()

        #expect(try Data(contentsOf: note) == words)
        #expect(Store.settings.object(forKey: "ai.memory") as? Bool == false)
        #expect(SettingsIndex.item("ai.memory") == nil)
    }
}
