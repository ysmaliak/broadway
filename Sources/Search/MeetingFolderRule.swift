import Foundation

struct MeetingFolderCall: Equatable {
    var key: String
    var name: String
}

struct MeetingFolderPage: Equatable {
    var id: UUID
    var from: UUID? = nil
    var pinned = false
    var agent = false
    var popup = false
    var group: UUID? = nil
    var call: MeetingFolderCall? = nil
}

struct MeetingFolderPlan: Equatable {
    var call: MeetingFolderCall
    var callTab: UUID
    var moving: [UUID]
    var folder: UUID?
}

enum MeetingFolderRule {
    static let made = "Made a folder for this meeting"
    static let reach = 8

    static func name(event: String?, service: MeetingLink.Service) -> String {
        let title = event?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? service.rawValue : title
    }

    static func key(_ url: URL) -> String? {
        guard let service = MeetingLink.service(of: url) else { return nil }
        return MeetingSpaceChoice.linkKey(url) ?? "\(service.name):\(url.absoluteString.lowercased())"
    }

    static func source(of page: MeetingFolderPage, in pages: [UUID: MeetingFolderPage]) -> MeetingFolderPage? {
        var at = page.from
        var visited: Set<UUID> = [page.id]
        for _ in 0..<reach {
            guard let id = at, visited.insert(id).inserted, let found = pages[id], !found.agent else { return nil }
            if found.call != nil { return found }
            at = found.from
        }
        return nil
    }

    static func plan(for opened: MeetingFolderPage, pages: [UUID: MeetingFolderPage], on: Bool, isPrivate: Bool,
                     declined: Set<String>, folders: [String: UUID]) -> MeetingFolderPlan? {
        guard on, !isPrivate, !opened.pinned, !opened.agent, !opened.popup, opened.call == nil,
              let source = source(of: opened, in: pages), let call = source.call, !declined.contains(call.key)
        else { return nil }
        let folder = folders[call.key]
        if let folder, opened.group == folder { return nil }
        var moving: [UUID] = []
        if !source.pinned, folder == nil || source.group != folder { moving.append(source.id) }
        moving.append(opened.id)
        return MeetingFolderPlan(call: call, callTab: source.id, moving: moving, folder: folder)
    }

    static func joining(_ call: MeetingFolderPage, folders: [String: UUID], declined: Set<String>, on: Bool,
                        isPrivate: Bool) -> UUID? {
        guard on, !isPrivate, !call.pinned, !call.agent, let key = call.call?.key, !declined.contains(key),
              let folder = folders[key], call.group != folder else { return nil }
        return folder
    }

    static func keepsLoose(byHand: Bool, meetingLive: Bool) -> Bool {
        byHand && meetingLive
    }

    static func restoredRow(_ now: [UUID], before: [UUID]) -> [UUID] {
        let place = Dictionary(before.enumerated().map { ($1, $0) }, uniquingKeysWith: { one, _ in one })
        let known = now.filter { place[$0] != nil }.sorted { place[$0]! < place[$1]! }
        var out = known
        for (index, id) in now.enumerated() where place[id] == nil {
            let at = index == 0 ? 0 : (out.firstIndex(of: now[index - 1]).map { $0 + 1 } ?? out.count)
            out.insert(id, at: at)
        }
        return out
    }
}
