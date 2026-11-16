import Foundation

@MainActor
enum PersonGroups {
    static let verbs: [PersonVerb] = [
        PersonVerb("groups", "list", .look) { call in
            let browser = call.browser
            let settings = AIGroups.shared
            let groups = browser.tabGroups.filter(\.ai)
            return ["on": settings.active(browser), "engine": settings.deciding?.title ?? "none",
                    "names": settings.naming?.title ?? "the sites",
                    "groups": groups.map { group in
                        ["id": PersonCommands.short(group.id), "name": group.name, "emoji": group.icon?.emoji ?? "",
                         "tabs": browser.tabs.filter { $0.groupID == group.id && BrowserToolbox.listed($0) }.count,
                         "renamed": group.userNamed] as [String: Any]
                    }]
        },
        PersonVerb("groups", "regroup", .arrange, first: { call in
            let settings = AIGroups.shared
            guard call.browser.prefs.usesTabGroups else {
                throw PersonRefusal("refused", "Tab groups are off")
            }
            guard settings.on else {
                throw PersonRefusal("refused", "Grouping tabs automatically is off", hint: "Turn it on with broadway settings open ai.groups")
            }
            guard settings.deciding != nil else {
                throw PersonRefusal("refused", "Grouping tabs needs Apple Intelligence on this Mac")
            }
        }) { call in
            let outcome = await AIGroups.shared.grouper(for: call.browser).regroup()
            var data: [String: Any] = ["joined": outcome.joined, "formed": outcome.formed, "renamed": outcome.renamed,
                                       "engine": AIGroups.shared.deciding?.title ?? "none"]
            if let note = AIGroups.shared.note { data["note"] = note }
            data["message"] = outcome == AIGrouper.Outcome() ? "Nothing to change" : "Grouped"
            return data
        },
    ]
}
