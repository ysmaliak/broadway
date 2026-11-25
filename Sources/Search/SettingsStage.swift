import AppKit

enum SettingsStageSpot: String, CaseIterable {
    case window, side, top, field, tabs, agents, page

    var words: String {
        switch self {
        case .window: return "the whole window"
        case .side: return "the sidebar"
        case .top: return "the top of the sidebar"
        case .field: return "the address field"
        case .tabs: return "the tab list"
        case .agents: return "the agents at the foot of the sidebar"
        case .page: return "the page"
        }
    }
}

enum SettingsStageClaim: Equatable {
    case spot(SettingsStageSpot)
    case rest
    case nowhere
}

enum SettingsStageMap {
    static let note = "settings.note"

    static let places: [SettingsPlace] = [
        SettingsPlace(page: .appearance), SettingsPlace(page: .websites), SettingsPlace(page: .tabs), SettingsPlace(page: .agents),
        SettingsPlace(page: .passwords), SettingsPlace(page: .privacy),
    ]

    static func pictured(_ place: SettingsPlace) -> Bool {
        places.contains { $0.page == place.page && $0.detail == place.detail }
    }

    static let rows: [String: SettingsStageClaim] = [
        "look": .spot(.window),
        "newtab.floating": .spot(.page),
        "homepage": .spot(.page),
        "app.icon": .nowhere,
        "sidebar.button": .spot(.top),
        "sidebar.selected": .spot(.tabs),

        "notifications.ask": .spot(.page),
        "privacy.forget": .spot(.page),
        "pageZoom": .spot(.page),
        "pages.pull": .spot(.page),
        "privacy.permissions": .spot(.page),

        "spaces.stacked": .spot(.side),
        "tabs.close.after": .spot(.tabs),

        "ai.groups": .spot(.tabs),
        "groups.openrouter": .spot(.tabs),
        "groups.meetings": .spot(.tabs),

        "ai.agents": .spot(.agents),
        "agents.mode": .spot(.agents),
        "agents.signIn": .spot(.agents),
        "ai.command": .spot(.agents),
        "agents.clients": .spot(.agents),

        "passwords.open": .spot(.page),
        "passwords.fill": .spot(.page),
        "passwords.never": .spot(.page),
        "passwords.apple": .spot(.page),
        "passwords.onepassword": .spot(.page),
        "apple.pairing": .spot(.page),
        "codes.gmail": .spot(.page),
        "autofill.profile": .spot(.page),
        "autofill.addresses": .spot(.page),
        "autofill.cards": .spot(.page),
        "autofill.remembered": .spot(.page),
        "editor.buttons": .rest,

        "shield": .spot(.page),
        "shield.trouble": .spot(.page),
        "shield.here": .spot(.page),
        "sites.keep": .spot(.page),
        "history.pageText": .spot(.field),
        "history.freezes": .rest,
        "clear.history": .spot(.field),
        "clear.cookies": .spot(.page),
        "clear.cache": .spot(.page),

        note: .rest,
    ]

    static let families: [(String, SettingsStageClaim)] = [
        ("site.", .spot(.page)),
        ("video.", .spot(.page)),
        ("mini.", .spot(.side)),
        ("agents.link.", .spot(.agents)),
        ("agents.hook", .rest),
        ("agents.site.", .spot(.page)),
        ("agents.signIn.", .spot(.page)),
        ("shield.paused.", .spot(.page)),
        ("autofill.address.", .spot(.page)),
        ("autofill.card.", .spot(.page)),
        ("field.", .rest),
    ]

    static func claim(_ row: String) -> SettingsStageClaim? {
        if let exact = rows[row] { return exact }
        return families.first { row.hasPrefix($0.0) }?.1
    }

    static func rest(_ place: SettingsPlace) -> SettingsStageSpot? {
        guard pictured(place) else { return nil }
        switch place.page {
        case .appearance: return .window
        case .websites, .passwords, .privacy: return .page
        case .tabs: return .tabs
        case .agents: return .agents
        case .general, .field, .links, .shortcuts, .liveFolders, .extensions: return nil
        }
    }

    static func spot(_ row: String?, at place: SettingsPlace) -> SettingsStageSpot? {
        guard let row, let claim = claim(row) else { return rest(place) }
        switch claim {
        case .spot(let spot): return spot
        case .rest: return rest(place)
        case .nowhere: return nil
        }
    }
}

struct SettingsStageScene: Equatable {
    enum Content: Equatable {
        case article
        case newTab
        case signIn(fills: Bool)
    }

    enum Ads: Equatable {
        case shown, gone, marked
    }

    var right = false
    var card = true
    var tint: SpaceLook? = nil
    var sideButton = true
    var stacked: Bool? = nil
    var content = Content.article
    var floating = false
    var zoom = 1.0
    var ads = Ads.gone
    var countdown = false
    var grouped = false
    var emoji = false
    var live = false
    var agents = false
    var door = false
    var video = false
    var quality: String? = nil
}

struct SettingsStageFacts: Equatable {
    var place: SettingsPlace
    var title: String
    var summary: String
    var crumb: String?
    var scene: SettingsStageScene
    var rest: SettingsStageSpot?
}

@MainActor
enum SettingsStageWords {
    static func facts(shell: SettingsShell, browser: Browser, space: UUID) -> SettingsStageFacts? {
        guard !shell.searching, SettingsStageMap.pictured(shell.trail.here) else { return nil }
        let place = shell.trail.here
        let head = head(place, browser: browser, space: space)
        let scene = scene(place, browser: browser, space: space)
        var rest = SettingsStageMap.rest(place)
        if rest == .agents, !scene.agents { rest = nil }
        return SettingsStageFacts(place: place, title: head.title, summary: head.summary, crumb: crumb(place),
                                  scene: scene, rest: rest)
    }

    static func crumb(_ place: SettingsPlace) -> String? {
        place.detail == nil ? nil : place.page.title
    }

    static func scene(_ place: SettingsPlace, browser: Browser, space: UUID) -> SettingsStageScene {
        let prefs = browser.prefs
        var scene = SettingsStageScene()
        scene.right = prefs.tabsLayout == .right
        scene.card = prefs.cards
        scene.tint = browser.space.look
        scene.sideButton = prefs.sideButton
        scene.stacked = prefs.usesSpaces ? prefs.stackedSpaces : nil
        scene.zoom = prefs.pageZoom
        let blocking = prefs.shielded && Shield.shared.trouble == nil
        scene.ads = blocking ? (place.page == .privacy && place.detail == nil ? .marked : .gone) : .shown
        scene.countdown = prefs.usesCalendars && Meetings.shared.hasAccess
        scene.grouped = AIGroups.shared.on
        scene.emoji = AIGroups.shared.emoji
        scene.live = !LiveFolderRows.folders(of: browser, space: space).isEmpty
        scene.agents = prefs.agentsOn
        scene.door = !Extensions.shared.installed.isEmpty
        guard place.detail == nil else { return scene }
        switch place.page {
        case .appearance:
            scene.floating = prefs.floatingNewTab
            if !prefs.floatingNewTab { scene.content = .newTab }
        case .passwords:
            scene.content = .signIn(fills: prefs.fillsAndSavesPasswords)
        case .websites:
            scene.video = true
            scene.quality = quality(prefs.videoQuality)
        default: break
        }
        return scene
    }

    static func quality(_ choice: VideoQuality.Choice) -> String? {
        switch choice {
        case .site, .last: return nil
        case .height(4320): return "8K"
        case .height(2160): return "4K"
        case .height(let height): return "\(height)p"
        }
    }

    static func head(_ place: SettingsPlace, browser: Browser, space: UUID) -> (title: String, summary: String) {
        guard let detail = place.detail else { return (place.page.title, place.page.summary) }
        switch detail {
        case .linkRule:
            let store = LinkRules.shared
            guard let id = place.folder, let rule = store.rule(id) else { return ("Rule", "This rule was removed") }
            return ("Rule \((store.index(of: id) ?? 0) + 1)", LinkRuleWords.sentence(rule, world: Browsers.linkWorld(from: browser)))
        case .liveFolder:
            guard let id = place.folder ?? LiveFolderRows.folders(of: browser, space: space).first?.id else {
                return ("Live Folder", "No live folders yet")
            }
            guard let folder = LiveFolders.shared.folder(id) else { return ("Live Folder", "This folder was removed") }
            return (folder.name, "Kept up to date from \(folder.source.siteName), on this Mac")
        case .languages:
            guard let name = place.space.flatMap({ id in browser.spaces.first { $0.id == id }?.name }) else {
                return (detail.title, detail.summary)
            }
            return ("Languages for “\(name)”", "What pages in this space read as your languages, in order")
        default:
            return (detail.title, detail.summary)
        }
    }
}
