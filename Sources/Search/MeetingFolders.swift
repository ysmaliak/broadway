import AppKit

@MainActor
final class MeetingFolders {
    static let shared = MeetingFolders()

    private(set) var joined: [UUID: MeetingFolderCall] = [:]
    private(set) var declined: Set<String> = []
    private var seen: Set<UUID> = []

    func joined(_ tab: Tab, link: URL, event: CalendarEvent?) {
        guard let key = MeetingFolderRule.key(link), let service = MeetingLink.service(of: link) else { return }
        joined[tab.id] = MeetingFolderCall(key: key, name: MeetingFolderRule.name(event: event?.title, service: service))
    }

    func decline(_ key: String) {
        declined.insert(key)
    }

    func firstSeen(_ tabs: [Tab]) -> [Tab] {
        tabs.filter { seen.insert($0.id).inserted }
    }

    func closed(_ tab: UUID) {
        joined[tab] = nil
        seen.remove(tab)
    }

    func forget() {
        joined = [:]
        declined = []
        seen = []
    }
}

extension Browser {
    func meetingCall(_ tab: Tab) -> MeetingFolderCall? {
        guard !tab.agent, !tab.shy, !tab.bench, let url = tab.address, let key = MeetingFolderRule.key(url),
              let service = MeetingLink.service(of: url) else { return nil }
        if let made = MeetingFolders.shared.joined[tab.id], made.key == key { return made }
        guard onCall(tab) else { return nil }
        return MeetingFolderCall(key: key, name: MeetingFolderRule.name(event: meetingEvent(for: url)?.title, service: service))
    }

    func meetingPage(_ tab: Tab) -> MeetingFolderPage {
        MeetingFolderPage(id: tab.id, from: tab.linkedFrom ?? tab.opener, pinned: tab.pin != nil, agent: tab.agent || tab.bench,
                          popup: tab.popup, group: group(of: tab), call: meetingCall(tab))
    }

    var meetingFolderIDs: [String: UUID] {
        Dictionary(tabGroups.compactMap { group in group.meeting.map { ($0, group.id) } }, uniquingKeysWith: { one, _ in one })
    }

    func meetingRowChanged(from old: [Tab]) {
        let before = Set(old.map(ObjectIdentifier.init))
        let added = tabs.filter { !before.contains(ObjectIdentifier($0)) }
        guard !added.isEmpty else { return }
        let fresh = MeetingFolders.shared.firstSeen(added).filter { $0.linkedFrom != nil || $0.opener != nil }
        guard !fresh.isEmpty, prefs.meetingFolders, !isPrivate else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tab in fresh { self.gatherForMeeting(tab) }
        }
    }

    func gatherForMeeting(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        var pages: [UUID: MeetingFolderPage] = [:]
        for each in tabs { pages[each.id] = meetingPage(each) }
        guard let opened = pages[tab.id],
              let plan = MeetingFolderRule.plan(for: opened, pages: pages, on: prefs.meetingFolders, isPrivate: isPrivate,
                                                declined: MeetingFolders.shared.declined, folders: meetingFolderIDs)
        else { return }
        let moving = plan.moving.compactMap { id in tabs.first { $0.id == id } }
        guard let folder = plan.folder else { return makeMeetingFolder(plan.call, holding: moving) }
        undoQuiet += 1
        for each in moving { move(each, toGroup: folder, staying: true) }
        undoQuiet -= 1
    }

    func makeMeetingFolder(_ call: MeetingFolderCall, holding moving: [Tab]) {
        let row = tabs.map(\.id)
        let previous = Dictionary(moving.map { ($0.id, $0.groupID) }, uniquingKeysWith: { one, _ in one })
        var folder = TabGroup(id: UUID(), name: call.name, collapsed: false)
        folder.pinned = false
        folder.meeting = call.key
        undoQuiet += 1
        tabGroups.append(folder)
        for each in moving { move(each, toGroup: folder.id, staying: true) }
        removeEmptyGroup(folder.id)
        undoQuiet -= 1
        guard tabGroups.contains(where: { $0.id == folder.id }) else { return }
        writeSession(now: true)
        announce(MeetingFolderRule.made, undo: { [weak self] in
            self?.undoMeetingFolder(folder.id, key: call.key, groups: previous, row: row)
        })
    }

    func undoMeetingFolder(_ id: UUID, key: String, groups: [UUID: UUID?], row: [UUID]) {
        MeetingFolders.shared.decline(key)
        guard tabGroups.contains(where: { $0.id == id }) else { return }
        undoQuiet += 1
        defer { undoQuiet -= 1 }
        removeTabGroup(id)
        for tab in tabs {
            guard let was = groups[tab.id] else { continue }
            tab.groupID = was.flatMap { group in tabGroups.contains { $0.id == group } ? group : nil }
        }
        let order = MeetingFolderRule.restoredRow(tabs.map(\.id), before: row)
        setRow(order.compactMap { id in tabs.first { $0.id == id } })
        arrangeGroupedTabs()
        writeSession(now: true)
    }

    func meetingJoined(_ link: URL, event: CalendarEvent?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPrivate,
                  let tab = self.tabs.first(where: { $0.address.map { $0 == link || MeetingLink.same($0, link) } == true })
            else { return }
            MeetingFolders.shared.joined(tab, link: link, event: event)
            guard let folder = MeetingFolderRule.joining(self.meetingPage(tab), folders: self.meetingFolderIDs,
                                                         declined: MeetingFolders.shared.declined,
                                                         on: self.prefs.meetingFolders,
                                                         isPrivate: self.isPrivate)
            else { return }
            self.undoQuiet += 1
            self.move(tab, toGroup: folder, staying: true)
            self.undoQuiet -= 1
        }
    }

    func meetingKeepsLoose(from source: Tab, link: Bool) -> Bool {
        guard !link, prefs.meetingFolders, let id = group(of: source),
              let key = tabGroups.first(where: { $0.id == id })?.meeting else { return false }
        return MeetingFolderRule.keepsLoose(byHand: !link, meetingLive: tabs.contains { group(of: $0) == id && meetingCall($0)?.key == key })
    }
}
