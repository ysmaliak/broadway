import Foundation

/// A named section of ordinary tabs in one space's tab layout.
/// Its tabs remain ordinary tabs; their own group IDs describe membership.
struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
    var parent: UUID? = nil
    var held = false
    var query: String? = nil
    var live = false
    var icon: TabIcon? = nil
    var ai = false
    var userNamed = false
    var madeName: String? = nil
    var userIcon = false
    var userFilled = false
    var aiEmoji: String? = nil
    var aiRefused: [String] = []
    var pinned = true
    var leads = false
    var foldedStacks: [String] = []

    var isPinned: Bool { live || pinned }
}

extension TabGroup {
    private enum Keys: String, CodingKey { case id, name, collapsed, parent, held, query, live, icon, ai, userNamed, madeName, userIcon, userFilled, aiEmoji, aiRefused, pinned, leads, foldedStacks }

    /// A group saved without its folded state is an open one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        parent = try? c.decodeIfPresent(UUID.self, forKey: .parent)
        held = (try? c.decodeIfPresent(Bool.self, forKey: .held)) ?? false
        query = try? c.decodeIfPresent(String.self, forKey: .query)
        live = (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? false
        icon = try? c.decodeIfPresent(TabIcon.self, forKey: .icon)
        ai = (try? c.decodeIfPresent(Bool.self, forKey: .ai)) ?? false
        userNamed = (try? c.decodeIfPresent(Bool.self, forKey: .userNamed)) ?? false
        madeName = try? c.decodeIfPresent(String.self, forKey: .madeName)
        userIcon = (try? c.decodeIfPresent(Bool.self, forKey: .userIcon)) ?? false
        userFilled = (try? c.decodeIfPresent(Bool.self, forKey: .userFilled)) ?? false
        aiEmoji = try? c.decodeIfPresent(String.self, forKey: .aiEmoji)
        aiRefused = (try? c.decodeIfPresent([String].self, forKey: .aiRefused)) ?? []
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? !ai
        leads = (try? c.decodeIfPresent(Bool.self, forKey: .leads)) ?? false
        foldedStacks = (try? c.decodeIfPresent([String].self, forKey: .foldedStacks)) ?? []
    }
}

extension TabGroup {
    /// The number an extension knows the group by, as Chrome numbers its
    /// groups. Taken from the identifier, so it stays the same for as long
    /// as the group lasts, across launches too, with nothing to keep.
    static func number(_ id: UUID) -> Int {
        let u = id.uuid
        let n = Int(u.0 & 0x7F) << 24 | Int(u.1) << 16 | Int(u.2) << 8 | Int(u.3)
        return n == 0 ? 1 : n
    }
}
