import Foundation

struct SettingsGroup: Identifiable {
    let id: String
    let page: SettingsPage
    let title: String
    let icon: String
    var detail: SettingsDetail? = nil
}

struct SettingsItem: Identifiable {
    enum Kind {
        case control
        case wide
        case note
    }

    let id: String
    let group: String
    let icon: String
    let title: String
    let detail: String
    var more: String? = nil
    var keys: [String] = []
    var words: [String] = []
    var kind: Kind = .control
    var parent: String? = nil
    var findOnly = false

    var page: SettingsPage { SettingsIndex.group(group)?.page ?? .general }
}

enum SettingsIndex {
    static let groups: [SettingsGroup] = [
        .init(id: "browser", page: .general, title: "The basics", icon: "globe.desk"),
        .init(id: "downloads", page: .general, title: "Downloads", icon: "arrow.down.circle"),
        .init(id: "meetings", page: .general, title: "Calendars", icon: "calendar"),
        .init(id: "updates", page: .general, title: "Updates", icon: "arrow.down.circle.dotted"),
        .init(id: "support", page: .general, title: "Help", icon: "questionmark.circle"),

        .init(id: "search", page: .field, title: "Searching", icon: "magnifyingglass"),
        .init(id: "keywords", page: .field, title: "Site shortcuts", icon: "character.cursor.ibeam"),
        .init(id: "quick", page: .field, title: "Quick Actions", icon: "bolt"),
        .init(id: "snippets", page: .field, title: "Snippets", icon: "text.insert"),

        .init(id: "theme", page: .appearance, title: "Look and new tabs", icon: "circle.lefthalf.filled"),
        .init(id: "icon", page: .appearance, title: "App icon", icon: "paintpalette"),
        .init(id: "sidebar", page: .appearance, title: "Sidebar", icon: "sidebar.left"),

        .init(id: "permissions", page: .websites, title: "Site permissions", icon: "checkmark.shield"),
        .init(id: "pages", page: .websites, title: "Pages", icon: "doc.richtext"),
        .init(id: "video", page: .websites, title: "Video", icon: "play.rectangle"),
        .init(id: "mini", page: .websites, title: "Mini player", icon: "music.note"),

        .init(id: "links.outside", page: .links, title: "From other apps", icon: "arrow.up.forward.app"),
        .init(id: "links", page: .links, title: "Rules", icon: "arrow.triangle.branch"),
        .init(id: "links.suggest", page: .links, title: "Suggestions", icon: "lightbulb"),
        .init(id: "links.clean", page: .links, title: "Clean-up", icon: "sparkles"),
        .init(id: "links.try", page: .links, title: "Try a link", icon: "play"),
        .init(id: "links.recent", page: .links, title: "Recent", icon: "clock"),

        .init(id: "tidy", page: .tabs, title: "Old tabs", icon: "timer"),
        .init(id: "tabs", page: .tabs, title: "Tabs, folders and pins", icon: "square.on.square"),

        .init(id: "keys", page: .shortcuts, title: "Keyboard shortcuts", icon: "command"),

        .init(id: "agents", page: .agents, title: "Agents", icon: "person.2"),

        .init(id: "live", page: .liveFolders, title: "Your live folders", icon: MenuSymbol.liveFolder),
        .init(id: "live.history", page: .liveFolders, title: "Add a live folder", icon: "folder.badge.plus"),
        .init(id: "live.offers", page: .liveFolders, title: "While you browse", icon: "folder.badge.plus"),

        .init(id: "passwords", page: .passwords, title: "Sign-ins", icon: "key"),
        .init(id: "apple", page: .passwords, title: "Apple Passwords", icon: "lock.rectangle.stack"),
        .init(id: "codes", page: .passwords, title: "One-time codes", icon: "message"),
        .init(id: "autofill", page: .passwords, title: "Forms", icon: "text.badge.checkmark"),

        .init(id: "blocking", page: .privacy, title: "Tracking", icon: "shield"),
        .init(id: "history", page: .privacy, title: "What Broadway keeps", icon: "clock"),
        .init(id: "clear", page: .privacy, title: "Danger zone", icon: "trash"),

    ]

    static let doors: Set<String> = ["search.shortcuts", "shortcuts", "privacy.permissions"]

    static func group(_ id: String) -> SettingsGroup? { groups.first { $0.id == id } }
    static func groups(of page: SettingsPage) -> [SettingsGroup] { groups.filter { $0.page == page } }
    static func items(in group: String) -> [SettingsItem] { items.filter { $0.group == group && !$0.findOnly } }

    static let items: [SettingsItem] = ([
        .init(id: "ai.agents", group: "agents", icon: "person.2.wave.2", title: "Let agents use Broadway",
              detail: "Claude Code, Codex and other MCP clients, through broadway. Off until you turn it on.", keys: ["agents.on"],
              words: ["mcp", "agents", "master switch", "claude code", "codex", "cursor", "ai"]),
        .init(id: "agents.mode", group: "agents", icon: "hand.raised", title: "Agents ask first",
              detail: "What an agent needs your yes for: Ask, Auto or Bypass", keys: ["agents.mode"],
              words: ["approval", "permission", "ask", "auto", "bypass", "confirm", "pay", "send", "delete", "your mac", "mac access",
                      "files", "terminal", "gate"]),
        .init(id: "agents.connected", group: "agents", icon: "person.2.wave.2", title: "Connected agents",
              detail: "Claude Code, Codex and scripts using Broadway, each with a card at the foot of the sidebar",
              words: ["agent mode", "connected", "disconnect", "claude code", "codex", "session", "agents area"], kind: .note, findOnly: true),
        .init(id: "agents.sites", group: "agents", icon: "globe", title: "Sites",
              detail: "Always Here and Never Here answers, by site", words: ["always here", "never here", "agent", "site"],
              kind: .note, findOnly: true),
        .init(id: "ai.command", group: "agents", icon: "terminal", title: "The broadway command",
              detail: "Set up broadway on your PATH, with shell completions and skills for Claude Code and Codex",
              words: ["cli", "terminal", "install", "setup", "doctor", "completions", "skill", "broadway status"], kind: .note, findOnly: true),
        .init(id: "ai.replies", group: "agents", icon: "arrowshape.turn.up.left", title: "Watch for a Reply",
              detail: "Checks a thread every 15 minutes on this Mac and tells you under Now",
              words: ["reply watching", "replies", "thread", "answer"], kind: .note, findOnly: true),

        .init(id: "ai.groups", group: "tabs", icon: "square.stack.3d.up", title: "Group tabs automatically",
              detail: "Related tabs find each other as you open them. Runs on this Mac. Nothing leaves it.",
              keys: [AIGroups.onKey],
              words: ["tab groups", "organize", "folders", "emoji", "apple intelligence", "sort tabs", "automatic folders"]),
        .init(id: "groups.openrouter", group: "tabs", icon: "key", title: AIGroupWords.keyTitle,
              detail: AIGroupWords.offer(remoteDecides: false),
              words: ["openrouter", "api key", "key", "folder names", "name folders", "group tabs", "keychain"]),

        .init(id: "general.default", group: "browser", icon: "link.badge.plus",
              title: "Default browser", detail: "Links from Mail, Slack and everywhere else open right here",
              words: ["default browser", "open links from other apps"]),
        .init(id: "general.import", group: "browser", icon: "square.and.arrow.down.on.square",
              title: "Bring your things over", detail: "Bookmarks, history, passwords and extensions from another browser",
              more: "Broadway reads it on this Mac, or from a file it exported. Nothing leaves your Mac.",
              words: ["import", "chrome", "safari", "arc", "migrate", "bring things over"]),
        .init(id: "languages", group: "browser", icon: "character.bubble",
              title: "Languages", detail: "The language sites pick for you, in every space and private windows",
              keys: ["languages"],
              words: ["language", "languages", "accept-language", "translate into", "preferred language", "locale", "english", "polish",
                      "navigator.languages", "use my mac's languages"]),
        .init(id: "spaces.languages", group: "tabs", icon: "character.bubble",
              title: "Language for this space", detail: "A space can have languages of its own, under Languages in its menu",
              words: ["language for this space", "space language", "accept-language", "translate into", "same as settings"],
              kind: .note, findOnly: true),
        .init(id: "look", group: "theme", icon: "circle.lefthalf.filled",
              title: "Theme", detail: "Light, dark, or whatever your Mac is doing. Pages follow along.",
              keys: ["look"], words: ["dark mode", "light mode", "theme", "system", "appearance", "auto"]),
        .init(id: "app.icon", group: "icon", icon: "paintpalette",
              title: "Icon", detail: "Broadway's icon in the Dock, the app switcher and About Broadway",
              keys: ["app.icon"], words: ["app icon", "icon colour", "icon color", "dock icon", "night", "day", "ink", "volt", "citrus"]),
        .init(id: "newtab.floating", group: "theme", icon: "rectangle.and.text.magnifyingglass",
              title: "New tab opens", detail: "A page of its own, or a field floating over what you're reading",
              more: "With the floating field, ⌘T raises it over the page, as in Arc. Return opens what you typed in a new tab. Escape, ⌘W or a click outside puts it away.",
              keys: ["newtab.floating"], words: ["command bar", "cmd t", "spotlight", "new tab page", "floating field", "start page", "new tab style", "new tabs show"]),
        .init(id: "sidebar.button", group: "sidebar", icon: "sidebar.left",
              title: "Sidebar button", detail: "A button at the top of the sidebar that hides and shows it",
              keys: ["sidebar.button"], words: ["sidebar button", "hide sidebar", "toggle sidebar", "collapse"]),
        .init(id: "search.engine", group: "search", icon: "magnifyingglass",
              title: "Search with", detail: "Where words that aren't an address go",
              keys: ["search.engine", "search.custom"], words: ["google", "duckduckgo", "engine", "kagi", "bing"]),
        .init(id: "search.suggest", group: "search", icon: "text.magnifyingglass",
              title: "Search suggestions", detail: "What you type is sent to your engine as you type",
              more: "Its suggestions show under the address field. Never from a private window, and never an address.",
              keys: ["search.suggest"], words: ["autocomplete", "suggest", "suggestions from your search engine"]),
        .init(id: IntegrationNow.key, group: "search", icon: "bolt",
              title: "Show in Now", detail: "Review requests and new Linear issues, at the top of the address field",
              more: "Read from your GitHub and Linear live folders in the space you are in",
              keys: [IntegrationNow.key], words: ["now", "review requests", "pull requests", "github", "linear", "issues", "field"]),
        .init(id: "search.shortcuts", group: "keywords", icon: "character.cursor.ibeam",
              title: "Address field shortcuts", detail: "Site shortcuts, Quick Actions and Snippets",
              words: ["keyword", "bang", "alias", "snippet", "quick actions", "shortcuts in the field"]),
        .init(id: "search.keywords", group: "keywords", icon: "character.cursor.ibeam",
              title: "Site shortcuts", detail: "A word before your search sends it to that site: “yt cats”",
              keys: ["search.keywords"], words: ["keyword", "bang"]),
        .init(id: "search.quickactions", group: "quick", icon: "bolt",
              title: "Quick Actions", detail: "Short names that open something new: doc, meet, and your own",
              more: "New document and New meeting follow what you use, such as Notion or Zoom, until you edit them. Your own have a short name, an address and an optional key.",
              keys: ["quickactions.json"], words: ["alias", "short name", "new document", "new meeting", "doc", "meet", "quick"]),
        .init(id: "field.snippets", group: "snippets", icon: "text.insert",
              title: "Snippets", detail: "Reusable local text, offered by ;keyword or title in the address field",
              keys: ["snippets.json"], words: ["snippet", "text expansion", "template", "фрагмент", "шаблон"]),
        .init(id: "downloads.folder", group: "downloads", icon: "folder",
              title: "Save downloads to", detail: "Where downloads go, or a save sheet for each one",
              keys: ["downloads", "downloads.ask"], words: ["download folder", "save to", "ask where to save each file", "ask each time"]),
        .init(id: "updates.version", group: "updates", icon: "info.circle",
              title: "Broadway", detail: "The version you have, and when Broadway last looked for a newer one",
              words: ["version", "build", "update", "check now", "check for updates", "last checked", "about", "sparkle"]),
        .init(id: "updates.check", group: "updates", icon: "arrow.triangle.2.circlepath",
              title: "Check for updates automatically", detail: "Once a day, from broadwaybrowser.com",
              keys: ["SUEnableAutomaticChecks"], words: ["update", "automatic updates", "check for updates", "new version"]),
        .init(id: "updates.install", group: "updates", icon: "arrow.down.app",
              title: "Install updates automatically", detail: "Downloaded in the background and installed when you quit",
              keys: ["SUAutomaticallyUpdate"], words: ["update", "automatic updates", "download updates", "install", "new version"]),
        .init(id: "support.email", group: "support", icon: "envelope",
              title: "Support", detail: "Opens an email to \(Support.address) with your Broadway and macOS versions",
              words: ["support", "help", "contact", "email", "mail", "feedback", "bug", "report a problem"]),
        .init(id: "pageZoom", group: "pages", icon: "plus.magnifyingglass",
              title: "Page zoom", detail: "Where every site starts. ⌘+ and ⌘− are remembered per site.",
              keys: ["pageZoom"], words: ["zoom", "size", "scale"]),
        .init(id: PullRefresh.key, group: "pages", icon: "arrow.clockwise",
              title: "Pull to refresh", detail: "At the top of a page, pull down with two fingers and let go to reload it",
              more: "The pull has to start at the top of the page, with fingers on the trackpad or a Magic Mouse. A glide never reloads, and neither does a scroll wheel. A page that scrolls something of its own under the pointer, handles the scroll itself, is pinched in, shows a video full screen, or holds text you typed and haven't sent, is left alone. ⌘R always reloads.",
              keys: [PullRefresh.key],
              words: ["pull to refresh", "pull down", "refresh", "reload", "overscroll", "trackpad", "gesture", "swipe down"]),
        .init(id: "video.quality", group: "video", icon: "sparkles.tv",
              title: "YouTube quality", detail: "What a YouTube video opens at, on YouTube and in its players on other sites",
              more: "A video without that quality opens at the best one below it. Picking another in the player lasts for that video. Private windows use a quality chosen here, but not the last one picked. Other sites choose their own quality.",
              keys: [VideoQuality.key],
              words: ["resolution", "quality", "youtube", "1080p", "1440p", "4k", "2160p", "hd", "default resolution", "video quality"]),
        .init(id: "video.speed", group: "video", icon: "gauge.with.dots.needle.67percent",
              title: "Remember video speed", detail: "A speed you set is how that site's next video opens",
              more: "Kept per site, however you set it: the site's own menu, Broadway's speed keys or the floating video. Live video, adverts, looping clips and silent previews play at their own speed. On YouTube, its own speed menu follows. Private windows take no part: nothing kept is used there and nothing is added. Clear History, and Forget Choices under Site permissions, forget every site's speed.",
              keys: [VideoSpeed.key],
              words: ["speed", "playback", "playback rate", "1.5", "2x", "faster", "slower", "per site", "tempo", "video speed"]),
        .init(id: Preferences.miniKey, group: "mini", icon: "music.note",
              title: "Show the mini player", detail: "Music, podcasts and audiobooks playing in another tab, at the foot of the sidebar",
              more: "It shows sound without a picture. A video with a picture floats instead. Click its artwork or title to go to the tab, in any space. The × hides it and the sound plays on. It comes back the next time that tab starts playing. Right-click it for the other buttons, mute, and other tabs playing.",
              keys: [Preferences.miniKey],
              words: ["mini player", "now playing", "music", "audio", "podcast", "audiobook", "player", "sidebar", "playing", "controls"]),
        .init(id: Preferences.miniSkipKey, group: "mini", icon: "goforward.15",
              title: "Skip by", detail: "How far back and forward the mini player's buttons jump",
              keys: [Preferences.miniSkipKey],
              words: ["skip", "seconds", "jump", "rewind", "fast forward", "10", "15", "30", "back", "forward"], parent: Preferences.miniKey),
        .init(id: Preferences.miniSpokenKey, group: "mini", icon: "book",
              title: "Long audio gets", detail: "The buttons for anything over 20 minutes, like an audiobook or a podcast",
              more: "Music gets previous and next where the site offers them. Something long gets skip back and forward unless you choose previous and next here. A site without them still gets skips. Right-click the player for the other pair.",
              keys: [Preferences.miniSpokenKey],
              words: ["audiobook", "podcast", "chapter", "previous", "next", "skip", "buttons", "long"], parent: Preferences.miniKey),
        .init(id: Preferences.miniSpeedKey, group: "mini", icon: "gauge.with.dots.needle.67percent",
              title: "Show speed", detail: "A speed button in the mini player, kept per site with Remember video speed",
              keys: [Preferences.miniSpeedKey],
              words: ["speed", "playback rate", "1.5", "2x", "faster", "slower", "audiobook", "podcast"], parent: Preferences.miniKey),
        .init(id: "tabs.close.after", group: "tidy", icon: "timer",
              title: "Tidy up old tabs", detail: "Pinned, named and grouped tabs stay. ⇧⌘T brings one back.",
              more: "Counted from when you last left the tab, while Broadway is quit too. Tabs in private windows, sound, calls and anything typed stay.",
              keys: ["tabs.close.after"], words: ["auto close", "archive", "clean up", "idle", "inactive", "unused", "close tabs you leave alone"]),
        .init(id: "calendars", group: "meetings", icon: "calendar",
              title: "Use your calendars", detail: "A countdown on a calendar pin, and a card before each meeting with Join",
              more: "macOS asks once for your calendars. Pin Google Calendar, Notion Calendar, Outlook, Cal.com, Reclaim or Fantastical for the countdown. It turns into Join a minute before, and ⌃⌘J joins. The card shows at the top right a minute before timed meetings you haven't declined, even with Broadway in the back. Nothing leaves this Mac.",
              keys: ["meetings.next", MeetingAlertPrefs.onKey],
              words: ["calendar", "join", "zoom", "meet", "teams", "webex", "facetime", "around", "huddle", "meeting alerts", "next meeting", "notification", "reminder", "remind", "rsvp", "invite"]),
        .init(id: "meetings.calendars", group: "meetings", icon: "calendar",
              title: "From these calendars", detail: "Uncheck a calendar to keep its meetings quiet",
              keys: [MeetingAlertPrefs.skipKey], words: ["calendar", "work", "family", "quiet"], kind: .wide, parent: "calendars"),
        .init(id: "meetings.faces", group: "meetings", icon: "person.crop.circle",
              title: "People's photos", detail: "Faces from Contacts on this Mac in meeting cards",
              more: "Broadway asks for Contacts only when you turn this on. Photos are looked up by email on this Mac and kept for a week. Nothing is sent anywhere.",
              keys: [ContactFaces.key], words: ["avatar", "photo", "picture", "face", "contacts", "attendees", "people"], parent: "calendars"),
        .init(id: "links.open", group: "links.outside", icon: "arrow.up.forward.app",
              title: "Open in", detail: "Where a link from another app goes when no rule takes it",
              words: ["external links", "default space", "links from other apps", "mail", "slack"]),
        .init(id: "links.choose", group: "links.outside", icon: "option",
              title: "Hold ⌥ to choose", detail: "Hold Option on a link in another app to pick where it opens, unless a live folder has it",
              more: "A link to something a live folder lists goes to its row without asking, while Go to the row if a live folder has it is on under Clean-up",
              words: ["option", "alt", "chooser", "picker", "ask"]),
        .init(id: "routes", group: "links", icon: "arrow.triangle.branch",
              title: "Rules", detail: "The first rule that matches a link decides where it opens",
              more: "A rule matches a site, a host, the start of an address, a pattern with *, or a regular expression, from another app, a named app or a page in Broadway. It opens the link in a space or folder, where the site is already open, a window, a peek or another app, or asks you.",
              words: ["air traffic control", "site routing", "space routing", "always open", "external links", "send a site somewhere",
                      "link rules", "redirect", "regex", "pattern", "wildcard"]),
        .init(id: "links.suggestions", group: "links.suggest", icon: "lightbulb",
              title: "Suggestions", detail: "Sites you keep in one space", words: ["habits", "suggest"], findOnly: true),
        .init(id: "links.tracking", group: "links.clean", icon: "eye.slash",
              title: "Take tracking off links from other apps", detail: "utm_ tags, fbclid, gclid and the like, before rules look at the address",
              words: ["clean links", "utm", "fbclid", "tracking parameters"]),
        .init(id: "links.unwrap", group: "links.clean", icon: "shippingbox",
              title: "Unwrap redirect links", detail: "Google, Facebook, Slack, Outlook Safe Links and others, read on this Mac",
              words: ["safelinks", "redirect", "wrapped", "google url", "slack-redir"]),
        .init(id: "links.openTab", group: "links.clean", icon: "square.on.square",
              title: "Go to the tab if it's already open", detail: "A link from another app to a page open in that space goes to its tab",
              words: ["duplicate tabs", "already open", "switch to tab"]),
        .init(id: "links.liveRow", group: "links.clean", icon: "dot.radiowaves.left.and.right",
              title: "Go to the row if a live folder has it", detail: "Links from other apps and links you open in a new tab go to that row, not a new tab",
              more: "A link you open in a new tab is a ⌘-click, the middle button, Open Link in New Tab, or a link that asks for a new window on another site. Opened behind, the row goes to the address and you stay where you are. A link to the row you are reading still gets a tab of its own. Holding ⌥ on a link from another app doesn't ask where it goes.",
              words: ["live folder", "pull request", "duplicate tabs", "already open", "row", "command click", "middle click", "new tab", "option"]),
        .init(id: "links.try", group: "links.try", icon: "play",
              title: "Try a link", detail: "See where an address would open, and why", words: ["test", "tester", "debug"], findOnly: true),
        .init(id: "links.recent", group: "links.recent", icon: "clock",
              title: "Recent", detail: "The last links a rule or you placed", words: ["log", "history"], findOnly: true),
        .init(id: "shortcuts", group: "keys", icon: "command",
              title: "Keyboard shortcuts", detail: "Every shortcut, with keys you can change",
              words: ["keys", "keyboard", "hotkey", "shortcut", "extension commands", "reset all"]),

        .init(id: "passwords.open", group: "passwords", icon: "key.viewfinder",
              title: "Your passwords", detail: "In the macOS keychain, shown with Touch ID", words: ["keychain"]),
        .init(id: "passwords.fill", group: "passwords", icon: "rectangle.and.pencil.and.ellipsis",
              title: "Fill and save passwords", detail: "Your accounts hang from a sign-in box, and new ones are offered once per site",
              keys: ["passwords.fill", "passwords.save"], words: ["autofill", "login", "save password", "offer to save passwords", "fill in sign-ins"]),
        .init(id: "passwords.never", group: "passwords", icon: "hand.raised.slash",
              title: "Sites never asked", detail: "Sites told to stop offering", words: ["never", "refused", "forget"]),
        .init(id: "passwords.apple", group: "apple", icon: "applelogo",
              title: "Apple Passwords",
              detail: AppleHelper.available ? "Your Passwords app's accounts under the sign-in box. Unofficial." : "Your Passwords app's accounts under the sign-in box. Coming soon.",
              more: AppleHelper.available ? "Broadway talks to the helper Apple made for its Chrome extension, as that extension. Never in private windows." : nil,
              keys: ["passwords.apple"], words: ["icloud keychain", "apple", "passwords app"]),
        .init(id: "codes.gmail", group: "codes", icon: "envelope",
              title: "Codes from Gmail", detail: "Offers a mailed code under the code box, and says when it looked",
              more: "Only while a code box has the caret, on a secure page of an ordinary tab, and only if this space is signed in to Google. Broadway reads your unread inbox feed from Google with that sign-in, in the account your Gmail tab is on, and tells you it did. Nothing is kept, no mail is marked read, and a code is never filled until you pick it.",
              keys: ["codes.gmail"], words: ["mail", "email", "e-mail", "one-time code", "otp", "2fa", "inbox"]),
        .init(id: "autofill.profile", group: "autofill", icon: "person.text.rectangle",
              title: "Your profile", detail: "Name, company, role, location and links, kept in the keychain",
              more: "Nothing here is written to a file. It stays on this Mac until you put it in a form. ⌥↩ fills a whole form from it.",
              words: ["name", "email", "phone", "identity", "fill whole forms", "form"]),
        .init(id: "autofill.addresses", group: "autofill", icon: "house",
              title: "Addresses", detail: "Shipping and billing addresses, kept in the keychain",
              words: ["shipping", "billing", "address", "street"]),
        .init(id: "autofill.cards", group: "autofill", icon: "creditcard",
              title: "Cards", detail: "Numbers stay in the keychain and come out only after Touch ID",
              more: "Never filled on an insecure page, and a private window asks first. The list shows the network and last four only.",
              words: ["credit card", "debit card", "payment", "visa", "mastercard"]),
        .init(id: "autofill.remembered", group: "autofill", icon: "clock.arrow.circlepath",
              title: "Remembered answers", detail: "What you typed into forms you sent, by site",
              more: "Never passwords, cards, codes or private windows. Kept on this Mac, and only filled when you ask.",
              words: ["form history", "autocomplete", "typed", "forget", "remembered"]),

        .init(id: "shield", group: "blocking", icon: "shield.lefthalf.filled",
              title: "Block ads and trackers", detail: "Inside WebKit, before a request is made, and YouTube's ads",
              more: "On YouTube, the ads announced in the player's own data are taken out before the video starts. Turn it off for one site from the site's row, or from Site Controls. Filter lists are fetched weekly from their publishers.",
              keys: ["shield"], words: ["adblock", "ad blocker", "ads", "youtube", "easylist", "filter lists"]),
        .init(id: "sites.keep", group: "blocking", icon: "eye.slash",
              title: "Prevent cross-site tracking", detail: "As in Safari. Private windows keep it on.",
              more: "Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome",
              keys: ["sites.keep"], words: ["itp", "cookies", "tracking"]),
        .init(id: "history.pageText", group: "history", icon: "text.page.badge.magnifyingglass",
              title: "Remember what pages say", detail: "Find a page by its words. Kept on this Mac. Private windows are never included.",
              more: "Broadway keeps the text of pages you visit so two or more words in the address field, or the History page, can find them. Nothing leaves this Mac. Pages drop out with their history. Turning this off forgets all of it.",
              keys: ["history.pageText"], words: ["full text", "search history", "index", "page text"]),
        .init(id: "notifications.ask", group: "permissions", icon: "bell.badge",
              title: "Let sites ask to send notifications", detail: "Only a site you allow reaches your Mac's notifications",
              keys: ["notifications.ask"], words: ["notifications", "alerts", "push"]),
        .init(id: "privacy.permissions", group: "permissions", icon: "hand.raised",
              title: "Site permissions", detail: "Camera, microphone, location, notifications, your network and pop-ups",
              words: ["permissions", "camera", "microphone", "location", "local network", "pop-ups"]),
        .init(id: "privacy.forget", group: "permissions", icon: "arrow.uturn.backward.circle",
              title: "What sites were allowed", detail: "Camera, microphone, location, notifications and your network, by site",
              words: ["permissions", "camera", "microphone", "location", "reset", "local network", "refused"]),
        .init(id: "clear.history", group: "clear", icon: "clock.arrow.circlepath",
              title: "History", detail: "Every address you have been to", words: ["clear history"]),
        .init(id: "clear.cookies", group: "clear", icon: "person.crop.circle.badge.xmark",
              title: "Cookies and sign-ins", detail: "Signs you out of every site", words: ["cookies", "sign out"]),
        .init(id: "clear.cache", group: "clear", icon: "internaldrive",
              title: "Cache", detail: "Only what was fetched to draw pages", words: ["clear cache"]),

        .init(id: "live.folders", group: "live", icon: MenuSymbol.liveFolder,
              title: "Live folders", detail: "Rename, pause, update or remove each live folder in this space",
              more: "Live folders read their site or feed from this Mac every five minutes while you use Broadway, less often while you are away and never while it sleeps, and keep their items as tabs in the sidebar",
              words: ["live folders", "live", "folders", "feeds", "rss", "atom", "pull requests", "prs", "github", "linear", "youtube",
                      "rename", "pause", "update now", "remove folder", "hidden items", "statuses", "status", "backlog",
                      "triage", "filter"], kind: .note),
        .init(id: "live.suggestions", group: "live.history", icon: "folder.badge.plus",
              title: "Live folders to add", detail: "GitHub, Linear, YouTube and the sites you open most, each ready to add",
              more: "Suggestions come first, read from this Mac's history only. Nothing is sent anywhere. Each space counts the visits made in it, and private windows keep no history. A folder reads its site with your sign-in in the space it is in.",
              words: ["live folders", "suggestions", "history", "pull requests", "prs", "review requests", "github", "issues",
                      "assigned issues", "notifications", "linear", "my issues", "mentions", "inbox", "created by me", "youtube",
                      "subscriptions", "feeds", "rss", "atom", "add", "integrations", "accounts"], kind: .note),
        .init(id: "live.offers", group: "live.offers", icon: "folder.badge.plus",
              title: "Suggest folders in the sidebar", detail: "On a site Broadway can follow, a folder you could add appears for a while",
              more: "Only on a site you keep coming back to, and only when the folder would have something in it. Turn one down or let it go, and that space isn't asked again. You can always add the folder here.",
              keys: ["live.suggest"],
              words: ["live folders", "suggestions", "suggest", "offer", "sidebar", "ghost", "dashed", "pull requests", "github", "linear",
                      "youtube", "add folder", "no thanks"]),
        .init(id: "live.offers.again", group: "live.offers", icon: "arrow.counterclockwise",
              title: "Turned down", detail: "Suggestions you turned down in this space",
              words: ["live folders", "suggestions", "turned down", "suggest again", "reset", "no thanks"], kind: .note),

        .init(id: "quit.confirm", group: "browser", icon: "power",
              title: "Ask before quitting", detail: "Now in the Broadway menu: Warn Before Quitting",
              keys: ["quit.confirm"], words: ["quit", "cmd q", "confirm before quitting"], kind: .note, findOnly: true),
        .init(id: "pages.dusk", group: "theme", icon: "moon",
              title: "Darken bright pages", detail: "Now in the View menu: Darken Bright Pages",
              keys: ["pages.dusk"], words: ["dark", "dusk", "night", "darken pages that stay light"], kind: .note, findOnly: true),
        .init(id: "tabs.layout", group: "sidebar", icon: "sidebar.left",
              title: "Sidebar on the right", detail: "Now in the View menu: Sidebar on Right",
              keys: ["sidebar.position"], words: ["sidebar", "vertical tabs", "column", "left", "right", "position", "side"],
              kind: .note, findOnly: true),
        .init(id: "spaces.stacked", group: "tabs", icon: "rectangle.split.1x2",
              title: "Spaces in the sidebar", detail: "Swipe between spaces, or keep every space in one list, each under its own heading",
              keys: [Preferences.stackedKey], words: ["stacked", "stack spaces", "one list", "all spaces", "sections", "single sidebar",
                                                      "vertical", "spaces in the sidebar"]),
        .init(id: "space.look", group: "theme", icon: "paintpalette",
              title: "Colour", detail: "Each space's own menu: Edit Look…",
              words: ["look", "colour", "color", "transparency", "grain", "glass", "paint", "tint"], kind: .note, findOnly: true),
        .init(id: "bookmarks.bar", group: "theme", icon: "bookmark",
              title: "Bookmarks bar", detail: "In the Bookmarks menu: Show Bookmarks Bar",
              keys: ["bookmarks.bar"], words: ["favorites bar"], kind: .note, findOnly: true),
        .init(id: "bench", group: "browser", icon: "terminal",
              title: "Let a script drive Broadway", detail: "Now in View › Developer: Allow Scripts to Drive Broadway",
              keys: ["bench"], words: ["automation", "script", "developer"], kind: .note, findOnly: true),
        .init(id: "autocorrect", group: "pages", icon: "textformat.abc.dottedunderline",
              title: "Correct spelling as you type", detail: "Now in Edit › Spelling and Grammar, as in Safari",
              keys: ["autocorrect"], words: ["autocorrect", "spelling", "spell"], kind: .note, findOnly: true),
        .init(id: "note.split", group: "tabs", icon: "rectangle.split.2x1",
              title: "Split View", detail: "Always there: drag a tab onto a page, or press ⌥⌘N",
              keys: ["splitView"], words: ["split", "side by side"], kind: .note, findOnly: true),
        .init(id: "note.groups", group: "tabs", icon: "folder",
              title: "Folders", detail: "Always there: right-click a tab › Move to Folder",
              keys: ["tabs.groups"], words: ["groups", "folders"], kind: .note, findOnly: true),
        .init(id: "note.panel", group: "pages", icon: "sidebar.right",
              title: "Sites in the side panel", detail: "Always there: View › Side Panel, or right-click a tab",
              keys: ["panel.sites"], words: ["side panel", "claude", "chatgpt"], kind: .note, findOnly: true),
        .init(id: "note.translate", group: "pages", icon: "translate",
              title: "Translate pages on this Mac", detail: "Always there: right-click a page › Translate Page",
              keys: ["translate.pages"], words: ["translate", "language"], kind: .note, findOnly: true),
        .init(id: "note.awake", group: "tidy", icon: "sun.max",
              title: "Keep selected sites awake", detail: "Always there: Keep This Site Awake, on the site's card",
              keys: ["tabs.keepAwake"], words: ["awake", "sleep"], kind: .note, findOnly: true),
        .init(id: "note.sitesearch", group: "search", icon: "arrow.right.to.line.compact",
              title: "Search a site from the address field", detail: "Always there: type red, then Tab, and search Reddit",
              keys: ["search.sites"], words: ["tab to search", "site search"], kind: .note, findOnly: true),
        .init(id: "note.sharedpins", group: "tabs", icon: "pin",
              title: "Pins in every space", detail: "Always there with Spaces: right-click a pin › Keep in Every Space",
              keys: ["pins.shared"], words: ["favorites", "shared pins"], kind: .note, findOnly: true),
        .init(id: "note.pinback", group: "tabs", icon: "arrow.uturn.backward",
              title: "A pin's number takes you back", detail: "Always there: press a pin's ⌘ number again to go back",
              keys: ["pins.numberBack"], words: ["cmd 1", "toggle"], kind: .note, findOnly: true),
        .init(id: "note.switcher", group: "keys", icon: "rectangle.stack",
              title: "Keys in the tab switcher", detail: "Always there: ⌃W, ⌃R, ⌃M and ⌃O while ⌃Tab is up",
              keys: ["switcher.keys"], words: ["ctrl tab", "switcher"], kind: .note, findOnly: true),
        .init(id: "note.links", group: "pages", icon: "link",
              title: "Show where links go", detail: "Always there: a link's address at the bottom of the page",
              keys: ["links.show"], words: ["status bar", "hover"], kind: .note, findOnly: true),
        .init(id: "note.flick", group: "pages", icon: "hand.raised.fingers.spread",
              title: "Flick the floating video to a corner", detail: "Always there: two fingers send it to the corner they point at",
              keys: ["float.flicks"], words: ["flick", "corner"], kind: .note, findOnly: true),
        .init(id: "note.floatkeys", group: "pages", icon: "keyboard",
              title: "Keys and speed for the floating video", detail: "Always there: Space plays, the arrows seek, M mutes, < and > change the speed",
              words: ["speed", "playback", "seek", "mute", "keyboard", "faster", "slower"], kind: .note, findOnly: true),
        .init(id: "note.answers", group: "search", icon: "equal.square",
              title: "Answers in the address field", detail: "Always there: type 15% of 80, 5 km in miles or 3pm london in sf",
              words: ["calculator", "calculate", "math", "convert", "conversion", "units", "time zone", "hex", "percent", "калькулятор"],
              kind: .note, findOnly: true),
        .init(id: "note.json", group: "pages", icon: "curlybraces",
              title: "JSON viewer", detail: "Always there: a JSON page opens as a tree, with Pretty and Raw beside it",
              keys: ["pages.json"], words: ["json", "api", "pretty print", "raw"], kind: .note, findOnly: true),
    ] as [SettingsItem])

    static func item(_ id: String) -> SettingsItem? { items.first { $0.id == id } }

    static func find(_ typed: String) -> [SettingsItem] {
        let words = typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let order = SettingsPage.allCases
        return items
            .filter { item in
                let group = SettingsIndex.group(item.group)
                let hay = ([item.title, item.detail, item.more ?? "", group?.title ?? "", item.page.title]
                    + item.words + item.keys).joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            .sorted { (order.firstIndex(of: $0.page) ?? 0, groupOrder($0.group)) < (order.firstIndex(of: $1.page) ?? 0, groupOrder($1.group)) }
    }

    private static func groupOrder(_ id: String) -> Int { groups.firstIndex { $0.id == id } ?? 0 }

    static func neverLine(_ count: Int) -> String {
        count == 1 ? "1 site told to stop offering" : "\(count) sites told to stop offering"
    }

    @MainActor static func applies(_ item: SettingsItem, _ prefs: Preferences) -> Bool {
        switch item.id {
        case "meetings.calendars", "meetings.faces": return prefs.usesCalendars
        case "passwords.never": return !Vault.never.isEmpty
        case "spaces.stacked": return prefs.usesSpaces
        case "ai.groups": return AIGroups.shared.deciding != nil
        case "groups.openrouter": return AIGroups.shared.remoteDecides || AIGroups.shared.available(.thisMac)
        case "passwords.apple": return AppleHelper.available
        case "updates.check": return Updates.runs
        case "updates.install": return Updates.runs && Updates.shared.canInstall
        default: return true
        }
    }

    static func needs(_ item: SettingsItem) -> String {
        switch item.id {
        case "meetings.calendars", "meetings.faces": return "Only while Broadway uses your calendars"
        case "passwords.never": return "No site has been told to stop offering"
        case "spaces.stacked": return "Only while you use spaces"
        case "ai.groups": return AIGroupWords.needs
        case "groups.openrouter": return "Needs Apple Intelligence on this Mac"
        case "passwords.apple": return item.detail
        case "updates.check": return UpdateWords.none
        case "updates.install": return Updates.runs ? "Only while Broadway checks for updates" : UpdateWords.none
        default: return ""
        }
    }
}

enum TabsLayout: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

extension Preferences {
    var tabsLayout: TabsLayout {
        get { sidePosition == .right ? .right : .left }
        set { sidePosition = newValue == .right ? .right : .left }
    }

    var fillsAndSavesPasswords: Bool {
        get { fillsPasswords && savesPasswords }
        set {
            fillsPasswords = newValue
            savesPasswords = newValue
        }
    }

    var usesCalendars: Bool {
        nextMeeting || MeetingAlertPrefs.shared.chosen == true
    }
}

extension SettingsIndex {
    @MainActor static func values(_ prefs: Preferences) -> [String: Any] {
        [
            "tabs.layout": prefs.tabsLayout.rawValue,
            "spaces.stacked": prefs.stackedSpaces ? "stacked" : "side",
            "downloads.ask": prefs.asksWhereToSave,
            "passwords.fill": prefs.fillsAndSavesPasswords,
            "calendars": prefs.usesCalendars,
            "newtab.floating": prefs.floatingNewTab,
            "sidebar.button": prefs.sideButton,
            "video.quality": prefs.videoQuality.raw,
            "video.speed": prefs.remembersSpeed,
            Preferences.miniKey: prefs.miniPlayer,
            Preferences.miniSkipKey: prefs.miniSkip,
            Preferences.miniSpokenKey: prefs.miniSpoken.rawValue,
            Preferences.miniSpeedKey: prefs.miniSpeed,
            PullRefresh.key: prefs.pullsToRefresh,
        ]
    }

    @MainActor static func apply(_ id: String, _ value: Any, to prefs: Preferences) -> Bool {
        switch id {
        case "tabs.layout":
            guard let layout = (value as? String).flatMap(TabsLayout.init) else { return false }
            prefs.tabsLayout = layout
        case "spaces.stacked":
            guard let choice = value as? String, ["side", "stacked"].contains(choice) else { return false }
            prefs.stackedSpaces = choice == "stacked"
        case "passwords.fill":
            guard let on = value as? Bool else { return false }
            prefs.fillsAndSavesPasswords = on
        case "downloads.ask":
            guard let on = value as? Bool else { return false }
            prefs.asksWhereToSave = on
        case "sidebar.button":
            guard let on = value as? Bool else { return false }
            prefs.sideButton = on
        case AppIcon.key:
            guard let icon = (value as? String).flatMap(AppIcon.init(rawValue:)) else { return false }
            prefs.appIcon = icon
        case "shield":
            guard let on = value as? Bool else { return false }
            prefs.shielded = on
        case "pageZoom":
            guard let zoom = value as? Double, Preferences.zooms.contains(zoom) else { return false }
            prefs.pageZoom = zoom
        case "newtab.floating":
            guard let on = value as? Bool else { return false }
            prefs.floatingNewTab = on
        case "video.quality":
            guard let choice = (value as? String).flatMap(VideoQuality.Choice.init(raw:)) else { return false }
            prefs.videoQuality = choice
        case "video.speed":
            guard let on = value as? Bool else { return false }
            prefs.remembersSpeed = on
        case PullRefresh.key:
            guard let on = value as? Bool else { return false }
            prefs.pullsToRefresh = on
        case Preferences.miniKey:
            guard let on = value as? Bool else { return false }
            prefs.miniPlayer = on
        case Preferences.miniSkipKey:
            guard let seconds = (value as? NSNumber)?.intValue, MiniRule.skips.contains(seconds) else { return false }
            prefs.miniSkip = seconds
        case Preferences.miniSpokenKey:
            guard let spoken = (value as? String).flatMap(MiniSpoken.init(rawValue:)) else { return false }
            prefs.miniSpoken = spoken
        case Preferences.miniSpeedKey:
            guard let on = value as? Bool else { return false }
            prefs.miniSpeed = on
        case "live.offers":
            guard let on = value as? Bool else { return false }
            prefs.suggestsLiveFolders = on
        default:
            return false
        }
        return true
    }

    static func describe(_ item: SettingsItem) -> [String: Any] {
        ["id": item.id, "page": item.page.rawValue, "group": item.group,
         "groupTitle": group(item.group)?.title ?? "", "title": item.title, "detail": item.detail,
         "keys": item.keys, "findOnly": item.findOnly, "note": item.kind == .note,
         "parent": item.parent ?? ""]
    }
}
