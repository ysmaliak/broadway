import AppKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, field, appearance, websites, links, tabs, shortcuts, agents, liveFolders = "livefolders", passwords, privacy, extensions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .field: return "Field"
        case .appearance: return "Appearance"
        case .websites: return "Websites"
        case .links: return "Links"
        case .tabs: return "Tabs"
        case .shortcuts: return "Shortcuts"
        case .agents: return "Agents"
        case .liveFolders: return "Live Folders"
        case .passwords: return "Passwords"
        case .privacy: return "Privacy"
        case .extensions: return "Extensions"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .field: return "magnifyingglass"
        case .appearance: return "circle.lefthalf.filled"
        case .websites: return "globe"
        case .links: return "arrow.triangle.branch"
        case .tabs: return "sidebar.left"
        case .shortcuts: return "command"
        case .agents: return "person.2"
        case .liveFolders: return MenuSymbol.liveFolder
        case .passwords: return "key"
        case .privacy: return "hand.raised"
        case .extensions: return "puzzlepiece.extension"
        }
    }

    var summary: String {
        switch self {
        case .general: return "The basics: your default browser, downloads, updates and calendars"
        case .field: return "The address field: what it searches, suggests and shortens"
        case .appearance: return "How Broadway looks: theme, new tabs and the sidebar"
        case .websites: return "What sites may do, and how pages are shown"
        case .links: return "Decide where a link opens: which space, folder, window or app"
        case .tabs: return "When old tabs close, and how spaces sit in the sidebar"
        case .shortcuts: return "Every key Broadway answers to, and yours"
        case .agents: return "Claude Code, Codex and other agents that use Broadway, and what they ask first"
        case .liveFolders: return "Folders that keep themselves up to date from your sites and feeds"
        case .passwords: return "Sign-ins, forms and one-time codes, filled in for you"
        case .privacy: return "What sites can see, and what Broadway remembers"
        case .extensions: return "Chrome extensions, from the Web Store or a folder of your own"
        }
    }

    static func named(_ name: String) -> SettingsPage? {
        switch name.lowercased() {
        case "general", "downloads", "about", "developers", "browsing", "calendars", "meetings": return .general
        case "live", "livefolders", "live-folders", "live folders", "feeds", "integrations", "github", "linear", "accounts": return .liveFolders
        case "fieldshortcuts", "quickactions", "quick-actions", "quick", "search", "searching", "snippets", "keywords",
             "address", "addressfield":
            return .field
        case "look", "theme", "sidebar", "newtab", "icon", "appicon", "app-icon": return .appearance
        case "routes", "links", "link-rules", "linkrules", "rules", "air traffic control": return .links
        case "sites", "permissions", "site-permissions", "pages", "zoom": return .websites
        case "spaces", "folders", "tabgroups", "tab-groups": return .tabs
        case "keyboard", "keys", "mouse": return .shortcuts
        case "applepasswords", "apple-passwords", "autofill": return .passwords
        case "ai", "agent", "mcp": return .agents
        default: return SettingsPage(rawValue: name.lowercased())
        }
    }

    static var blocks: [[SettingsPage]] {
        [[.general, .field, .appearance, .websites, .links, .tabs, .shortcuts], [.agents, .liveFolders, .passwords, .privacy, .extensions]]
    }
}

enum SettingsSize {
    static let rail: CGFloat = 210
    static let minimum = CGSize(width: 720, height: 480)
    static let opening = CGSize(width: 860, height: 640)
}

enum SettingsDetail: String, CaseIterable, Identifiable {
    case linkRule = "linkrule"
    case liveFolder = "livefolder"
    case languages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linkRule: return "Rule"
        case .liveFolder: return "Live Folder"
        case .languages: return "Languages"
        }
    }

    var summary: String {
        switch self {
        case .linkRule: return "One rule: which links it takes and where they open"
        case .liveFolder: return "One live folder: its name, where it reads from and when"
        case .languages: return "The languages you read. Sites get the first one."
        }
    }

    var page: SettingsPage {
        switch self {
        case .linkRule: return .links
        case .liveFolder: return .liveFolders
        case .languages: return .general
        }
    }

    var item: String? {
        switch self {
        case .languages: return PreferredLanguages.key
        case .linkRule, .liveFolder: return nil
        }
    }

    var symbol: String {
        switch self {
        case .linkRule: return "arrow.triangle.branch"
        case .liveFolder: return MenuSymbol.liveFolder
        case .languages: return "character.bubble"
        }
    }

    static func named(_ name: String) -> SettingsDetail? {
        switch name.lowercased() {
        case "linkrule", "rule": return .linkRule
        case "livefolder": return .liveFolder
        case "languages", "language": return .languages
        default: return nil
        }
    }

    static func opened(by item: String) -> SettingsDetail? {
        allCases.first { $0.item == item }
    }
}

struct SettingsPlace: Equatable {
    var page: SettingsPage
    var detail: SettingsDetail? = nil
    var folder: UUID? = nil
    var space: UUID? = nil
}

struct SettingsTrail: Equatable {
    private(set) var here: SettingsPlace
    private(set) var behind: [SettingsPlace] = []
    private(set) var ahead: [SettingsPlace] = []

    init(page: SettingsPage) {
        here = SettingsPlace(page: page)
    }

    var page: SettingsPage { here.page }
    var detail: SettingsDetail? { here.detail }
    var folder: UUID? { here.folder }
    var space: UUID? { here.space }
    var canGoBack: Bool { !behind.isEmpty }
    var canGoForward: Bool { !ahead.isEmpty }

    mutating func go(to page: SettingsPage) {
        arrive(at: SettingsPlace(page: page))
    }

    mutating func open(_ detail: SettingsDetail, folder: UUID? = nil, space: UUID? = nil) {
        arrive(at: SettingsPlace(page: detail.page, detail: detail, folder: folder, space: space))
    }

    @discardableResult
    mutating func back() -> Bool {
        guard let last = behind.popLast() else { return false }
        ahead.append(here)
        here = last
        return true
    }

    @discardableResult
    mutating func forward() -> Bool {
        guard let next = ahead.popLast() else { return false }
        behind.append(here)
        here = next
        return true
    }

    @discardableResult
    mutating func up() -> Bool {
        guard detail != nil else { return false }
        let parent = SettingsPlace(page: page)
        if behind.last == parent { return back() }
        arrive(at: parent)
        return true
    }

    private mutating func arrive(at place: SettingsPlace) {
        guard place != here else { return }
        behind.append(here)
        ahead = []
        here = place
    }
}
