import AppKit

extension Bench {
    func meetingFolderCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "meetfolder only works on a --test run"]); return }
        switch request["action"] as? String ?? "state" {
        case "undo": browser.undoAnnounced()
        case "forget": MeetingFolders.shared.forget()
        case "set": if let on = request["on"] as? Bool { browser.prefs.meetingFolders = on }
        default: break
        }
        answer([
            "on": browser.prefs.meetingFolders,
            "announced": browser.announcement ?? "",
            "undo": browser.announcedUndo != nil,
            "declined": Array(MeetingFolders.shared.declined),
            "folders": browser.tabGroups.filter { $0.meeting != nil }.map { group in
                ["name": group.name, "meeting": group.meeting ?? "", "tabs": browser.tabs(in: group.id).map(Bench.short)] as [String: Any]
            },
        ])
    }
}
