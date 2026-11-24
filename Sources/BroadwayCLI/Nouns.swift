import Foundation

struct Verb {
    var line: String
    var summary: String
    var about = ""
    var examples: [String] = []
    var columns: [String] = []
    var hidden = false
    var fromStdin = false

    init(_ line: String, _ summary: String, about: String = "", examples: [String] = [], columns: [String] = [], hidden: Bool = false, fromStdin: Bool = false) {
        self.line = line
        self.summary = summary
        self.about = about
        self.examples = examples
        self.columns = columns
        self.hidden = hidden
        self.fromStdin = fromStdin
    }

    var words: [String] { Grammar.pieces(line) }
    var noun: String { words.first ?? "" }
    var name: String { words.count > 1 ? words[1] : "" }
    var fullName: String { "\(noun) \(name)" }
    var usage: String { "broadway \(line)" }

    var command: Command {
        var built = Grammar.command(words.dropFirst(2).map { $0 }, name: fullName, summary: summary, about: about, columns: columns)
        built.wholeUsage = usage
        built.examples = examples.isEmpty ? [usage] : examples
        return built
    }
}

struct Noun {
    var name: String
    var summary: String
    var group: String
    var first: String?
    var loose: Bool
    var verbs: [Verb]

    init(_ name: String, _ summary: String, group: String, first: String? = "list", loose: Bool = false, _ verbs: [Verb]) {
        self.name = name
        self.summary = summary
        self.group = group
        self.first = first
        self.loose = loose
        self.verbs = verbs
    }

    func verb(_ word: String) -> Verb? { verbs.first { $0.name == word } }
    var shown: [Verb] { verbs.filter { !$0.hidden } }
    var names: [String] { shown.map(\.name) }
}

enum Grammar {
    static func pieces(_ line: String) -> [String] {
        var found: [String] = []
        var current = ""
        var depth = 0
        for character in line {
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1 }
            if character == " ", depth == 0 {
                if !current.isEmpty { found.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { found.append(current) }
        return found
    }

    private static func parameter(_ name: String, type: String = "string", required: Bool = false, choices: [String] = [], many: Bool = false) -> [String: Any] {
        var found: [String: Any] = ["name": name, "type": type, "required": required, "many": many]
        if !choices.isEmpty { found["choices"] = choices }
        return found
    }

    static func command(_ pieces: [String], name: String, summary: String, about: String, columns: [String]) -> Command {
        var positional: [[String: Any]] = []
        var flags: [[String: Any]] = []
        var tabbed = false
        for piece in pieces {
            let inner = piece.trimmingCharacters(in: CharacterSet(charactersIn: "[]<>"))
            if inner.hasPrefix("--") {
                let parts = inner.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                let flag = parts[0]
                if flag == "tab" {
                    tabbed = true
                    continue
                }
                guard parts.count == 2 else {
                    flags.append(parameter(flag, type: "boolean"))
                    continue
                }
                let value = parts[1]
                if value.contains("|") {
                    flags.append(parameter(flag, choices: value.components(separatedBy: "|")))
                } else {
                    flags.append(parameter(flag, type: value == "N" ? "number" : "string"))
                }
                continue
            }
            let many = inner.hasSuffix("...")
            var bare = many ? String(inner.dropLast(3)) : inner
            if bare.contains(" "), let last = bare.split(separator: " ").last {
                bare = last.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) + "s"
            }
            let entry = parameter(bare, required: piece.hasPrefix("<"), many: many)
            positional.append(entry)
            flags.append(entry)
        }
        var found: [String: Any] = ["name": name, "tool": "", "summary": summary, "description": about.isEmpty ? summary + "." : summary + ".\n\n" + about,
                                    "tabbed": tabbed, "reads": false, "positional": positional, "flags": flags]
        if !columns.isEmpty { found["columns"] = columns }
        return Command(found)
    }
}

enum Nouns {
    static let groups = ["Spaces and tabs", "Your stuff", "Page", "Settings", "AI"]

    static let all: [Noun] = [
        Noun("spaces", "Your spaces", group: "Spaces and tabs", [
            Verb("spaces list", "List the spaces and which is on screen", examples: ["broadway spaces", "broadway spaces list --json"], columns: ["name", "tabs", "current", "accounts", "colour"]),
            Verb("spaces switch <space>", "Switch to a space", examples: ["broadway spaces switch Work", "broadway space Work"]),
            Verb("spaces new <name> [--fresh] [--icon SYMBOL] [--switch]", "Make a space", about: "It stays behind unless --switch. It gets shared accounts: it stays signed in to the sites your other spaces use. --fresh gives it separate accounts: every site starts signed out, with cookies of its own.", examples: ["broadway spaces new Work", "broadway spaces new Clients --fresh --switch"]),
            Verb("spaces rename <space> <name>", "Rename a space"),
            Verb("spaces move <space> <position>", "Move a space among the others", about: "Position 1 is first. ⌃1–⌃9 follow the order."),
            Verb("spaces icon <space> <symbol>", "Change a space's icon"),
            Verb("spaces colour <space> <colour>", "Change a space's colour", about: "One of graphite, gray, paper, coral, peach, sage, sky, lavender or rose, by id or name. Its transparency, grain and glass stay as they are. A custom colour or a picture is the person's to choose, in the space's menu: Edit Look…", examples: ["broadway spaces colour Work sage"]),
            Verb("spaces delete <space>", "Delete a space and close its tabs"),
        ]),
        Noun("space", "Which space is on screen, or go to one", group: "Spaces and tabs", first: "show", [
            Verb("space show [space]", "Say which space is on screen, or go to one", examples: ["broadway space", "broadway space Work"]),
        ]),
        Noun("tabs", "The open tabs", group: "Spaces and tabs", [
            Verb("tabs list [--space NAME] [--all] [--pinned]", "List the open tabs", about: "For an agent with a session: its own tabs, the current one marked, then how many the person has. --all lists every tab in every space. Private windows are not listed.",
                 examples: ["broadway tabs", "broadway tabs --all", "broadway tabs --space Work --json"], columns: ["id", "space", "title", "url"]),
            Verb("tabs show <tab>", "Everything about one tab"),
            Verb("tabs new [url] [--space NAME] [--folder NAME] [--front]", "Open a tab of the person's own", about: "Unlike broadway open, this is the person's tab: it stays in history", examples: ["broadway tabs new https://example.com --space Work"]),
            Verb("tabs open <url> [--space NAME]", "Open an agent tab in a space", hidden: true),
            Verb("tabs select <tab>", "Bring a tab to the front", about: "In another space, that space comes too"),
            Verb("tabs close <tab...>", "Close tabs", about: "An agent's tab closes at once. The person's own asks in Broadway first. broadway tabs reopen brings back those closed in the space on screen.", examples: ["broadway tabs close 1a2b3c4d", "broadway tabs close 1a2b3c4d 5e6f7a8b"]),
            Verb("tabs reopen", "Reopen the last tab closed"),
            Verb("tabs closed", "List recently closed tabs", columns: ["title", "url"]),
            Verb("tabs move <tab> [--space NAME] [--folder NAME] [--no-folder] [--to N]", "Move a tab", examples: ["broadway tabs move 1a2b3c4d --space Work", "broadway tabs move 1a2b3c4d --folder Reading", "broadway tabs move 1a2b3c4d --to 1"]),
            Verb("tabs pin <tab>", "Pin a tab"),
            Verb("tabs unpin <tab>", "Unpin a tab"),
            Verb("tabs rename <tab> [name]", "Name a tab, or clear its name"),
            Verb("tabs sleep <tab...>", "Put tabs to sleep", about: "Says what keeps a tab awake when it can't sleep", columns: ["id", "state"]),
            Verb("tabs wake <tab...>", "Wake tabs", columns: ["id", "state"]),
            Verb("tabs mute <tab...>", "Mute tabs", columns: ["id", "state"]),
            Verb("tabs unmute <tab...>", "Unmute tabs", columns: ["id", "state"]),
            Verb("tabs keep <tab>", "Make an agent's tab the person's", about: "Run it before broadway agents done for a page the person should see. It stays open as theirs when your tabs close."),
        ]),
        Noun("folders", "Folders of tabs in the space on screen", group: "Spaces and tabs", [
            Verb("folders list", "List the folders", columns: ["id", "name", "tabs", "folded", "pinned", "parent"]),
            Verb("folders new <name> [--in FOLDER] [--tabs IDS]", "Make a folder", examples: ["broadway folders new Reading", "broadway folders new Trip --tabs 1a2b3c4d,5e6f7a8b"]),
            Verb("folders rename <folder> <name>", "Rename a folder"),
            Verb("folders fold <folder>", "Fold a folder"),
            Verb("folders unfold <folder>", "Unfold a folder"),
            Verb("folders pin <folder>", "Pin a folder up top with the live folders"),
            Verb("folders unpin <folder>", "Unpin a folder into the tab list"),
            Verb("folders add <folder> <tab...>", "Put tabs in a folder"),
            Verb("folders remove <tab...>", "Take tabs out of their folders"),
            Verb("folders delete <folder>", "Remove a folder and keep its tabs"),
            Verb("folders close <folder>", "Close a folder and its tabs"),
        ]),
        Noun("groups", "Tab groups Broadway made with AI in the space on screen", group: "Spaces and tabs", [
            Verb("groups list", "List the AI groups", columns: ["id", "emoji", "name", "tabs", "renamed"]),
            Verb("groups regroup", "Group the space's loose tabs now", about: "Runs on this Mac with Apple Intelligence. Folders you made are never touched."),
        ]),
        Noun("split", "Split View", group: "Spaces and tabs", [
            Verb("split list", "List the pairs", columns: ["id", "left", "right", "axis", "front"]),
            Verb("split start <left> <right>", "Show two tabs side by side"),
            Verb("split swap", "Swap the pair on screen"),
            Verb("split even", "Even out the pair on screen"),
            Verb("split detach <tab>", "Take a tab out of its pair"),
        ]),
        Noun("windows", "Broadway's windows", group: "Spaces and tabs", [
            Verb("windows list", "List the windows", columns: ["id", "space", "tabs", "front"]),
            Verb("windows new", "Open a window"),
        ]),
        Noun("bookmarks", "Your bookmarks", group: "Your stuff", [
            Verb("bookmarks list [query] [--folder NAME]", "List bookmarks", examples: ["broadway bookmarks", "broadway bookmarks list github", "broadway bookmarks list --folder Work"], columns: ["id", "title", "url", "folder"]),
            Verb("bookmarks add <url> [--title TEXT] [--folder NAME]", "Add a bookmark"),
            Verb("bookmarks folder <name> [--in NAME]", "Make a bookmark folder"),
            Verb("bookmarks rename <id> <title>", "Rename a bookmark"),
            Verb("bookmarks move <id> [--folder NAME]", "Move a bookmark to a folder, or to the top"),
            Verb("bookmarks open <id>", "Open a bookmark in one of the person's tabs"),
            Verb("bookmarks delete <id>", "Remove a bookmark", examples: ["broadway bookmarks delete 1a2b3c4d"]),
        ]),
        Noun("downloads", "Downloads", group: "Your stuff", [
            Verb("downloads list", "List downloads", columns: ["id", "state", "name", "progress", "path"]),
            Verb("downloads pause <id>", "Pause a download"),
            Verb("downloads resume <id>", "Resume a download"),
            Verb("downloads retry <id>", "Try a failed download again"),
            Verb("downloads cancel <id>", "Cancel a download"),
            Verb("downloads forget <id>", "Drop a finished download from the list", about: "The file stays on disk"),
            Verb("downloads clear", "Drop every finished download from the list", about: "The files stay on disk"),
        ]),
        Noun("files", "Downloads, and files you gave to sites", group: "Your stuff", [
            Verb("files list [query]", "List files", columns: ["kind", "name", "site", "path"]),
        ]),
        Noun("history", "Browsing history", group: "Your stuff", loose: true, [
            Verb("history list [query] [--limit N]", "Search history, newest first", examples: ["broadway history github", "broadway history --limit 5"], columns: ["last", "title", "url"]),
            Verb("history delete [url] [--site HOST] [--since TIME]", "Forget history", about: "One address, one site, or everything since a time like 30m, 2h or 7d", examples: ["broadway history delete https://example.com/page", "broadway history delete --site example.com", "broadway history delete --since 1h"]),
            Verb("history clear", "Clear all history"),
        ]),
        Noun("live", "Live Folders", group: "Your stuff", [
            Verb("live list", "List live folders", columns: ["id", "name", "state", "items", "source"]),
            Verb("live show <id>", "What a live folder holds, a pull request folder's lists and whether it hides draft review requests, and a Linear folder's statuses", columns: ["title", "label", "checks", "url"]),
            Verb("live add <name> <source> [--space NAME]", "Follow a feed, a site, a GitHub owner/repository, or github:reviews, github:mine, github:issues, github:notifications, linear:assigned, linear:mentions, linear:inbox, linear:cycle/TEAM. GitHub and Linear folders read with the space's sign-in.", examples: ["broadway live add News https://example.com/feed.xml", "broadway live add WebKit WebKit/WebKit", "broadway live add Reviews github:reviews", "broadway live add \"My Issues\" linear:assigned"]),
            Verb("live rename <id> <name>", "Rename a live folder"),
            Verb("live statuses <id> <status...>", "Choose which statuses a Linear folder shows", about: "For assigned, created and cycle folders. The statuses are triage, backlog, todo and progress, and each team's own statuses fall under one of them. Backlog is left out until you name it. Done and canceled issues stay out of assigned and created folders.", examples: ["broadway live statuses 1a2b3c4d triage todo progress backlog", "broadway live statuses 1a2b3c4d progress"]),
            Verb("live drafts <id> <choice>", "Hide or show draft review requests", about: "For a pull request folder with Review Requests or Team Reviews. hide reads those lists without drafts. Your own drafts and drafts assigned to you still show through Created by You and Assigned to You. show brings them back.", examples: ["broadway live drafts 1a2b3c4d hide", "broadway live drafts 1a2b3c4d show"]),
            Verb("live pause <id>", "Stop reading a live folder"),
            Verb("live resume <id>", "Read a live folder again"),
            Verb("live update [id]", "Read one or all now"),
            Verb("live delete <id>", "Remove a live folder"),
        ]),
        Noun("logins", "Sign-ins kept in Broadway", group: "Your stuff", [
            Verb("logins list [site]", "List sign-ins by site", about: "Site and user name only. Passwords are never shown. broadway fill login uses one.", columns: ["site", "user", "used"]),
        ]),
        Noun("fill", "Fill a form from what Broadway keeps, or with your values: broadway fill '{\"@e4\": \"Sam\"}'", group: "Your stuff", first: nil, [
            Verb("fill login [--account USER] [--tab ID]", "Sign in on the page", about: "Asks in Broadway every time. Broadway fills the page itself: the password is never shown. Press the page's button afterwards.", examples: ["broadway fill login --tab 1a2b3c4d"]),
            Verb("fill details [--tab ID]", "Fill the form with your details", about: "Asks in Broadway every time"),
            Verb("fill card [--tab ID]", "Fill the form with your card", about: "Asks in Broadway every time, and needs Touch ID. The number is never shown."),
        ]),
        Noun("page", "The page in a tab", group: "Page", first: "info", [
            Verb("page info [--tab ID]", "Title, address, zoom and translation"),
            Verb("page reload [--tab ID]", "Reload a page"),
            Verb("page back [--tab ID]", "Go back"),
            Verb("page forward [--tab ID]", "Go forward"),
            Verb("page find <text> [--case] [--words] [--tab ID]", "Count a word on the page and show its lines", about: "Looks at the page's words, never at what is typed in a box", examples: ["broadway page find price", "broadway page find price --case"], columns: ["line", "text"]),
            Verb("page translate [language] [--tab ID]", "Translate the page on this Mac", examples: ["broadway translate", "broadway translate de"]),
            Verb("page original [--tab ID]", "Show the page as it was written"),
            Verb("page pdf [--tab ID]", "Save the page as a PDF", about: "Password and card boxes and embedded frames are blanked, as in broadway shot", examples: ["broadway pdf -o page.pdf", "broadway pdf > page.pdf"]),
            Verb("page zoom [value] [--tab ID]", "Say the zoom, or change it: a percent, in, out or reset", examples: ["broadway zoom", "broadway zoom 125", "broadway zoom reset"]),
        ]),
        Noun("site", "The site a tab is on", group: "Page", first: "info", [
            Verb("site info [--tab ID]", "Zoom, shields, permissions and what is hidden"),
            Verb("site hide <selector> [--label TEXT] [--tab ID]", "Hide an element on this site for good", about: "Takes a CSS selector", examples: ["broadway site hide '.cookie-banner'"]),
            Verb("site hidden [--tab ID]", "What is hidden on this site", columns: ["selector", "label", "date"]),
            Verb("site unhide [selector] [--all] [--tab ID]", "Bring back what was hidden"),
        ]),
        Noun("settings", "Settings", group: "Settings", [
            Verb("settings list [--page PAGE] [--can-set]", "List settings, what each takes and who may change it", about: "--can-set lists only what this command can change. With agents off, without their values. Where a setting has nothing to set, instead names the command or the place that does the job.", examples: ["broadway settings list --can-set", "broadway settings list --page appearance --json"], columns: ["id", "value", "title", "takes"]),
            Verb("settings find <words...>", "Find a setting", columns: ["id", "value", "title", "takes"]),
            Verb("settings get <setting>", "Read a setting"),
            Verb("settings set <setting> <value> [<setting> <value>...]", "Change one setting, or several at once", about: "Several pairs are all checked before anything changes, so one refused or wrong value changes nothing. When the person must say yes, it is one question for the whole line. The answer gives each setting's old and new value. What weakens safety can only be changed in Broadway: broadway settings open ID goes there. languages takes a comma list in order, or mac.", examples: ["broadway settings set look dark", "broadway settings set look dark pageZoom 110 newtab.floating true", "broadway settings set languages en-GB,pl"], columns: ["id", "was", "value"]),
            Verb("settings open [setting]", "Open Settings in Broadway"),
        ]),
        Noun("shortcuts", "Keyboard shortcuts", group: "Settings", [
            Verb("shortcuts list [query]", "List shortcuts", columns: ["id", "key", "title", "section"]),
            Verb("shortcuts set <shortcut> <keys>", "Give a command a key", examples: ["broadway shortcuts set view.reload cmd+shift+r"]),
            Verb("shortcuts clear <shortcut>", "Take a command's key away"),
            Verb("shortcuts reset [shortcut] [--all]", "Put a key back"),
        ]),
        Noun("links", "Link rules: the space a link opens in", group: "Settings", [
            Verb("links list", "List the rules, first to last", about: "The first rule that fits a link decides where it opens", columns: ["id", "match", "opens", "on"]),
            Verb("links add <match> [--space NAME] [--kind site|host|starts|contains|pattern|regex] [--app NAME]", "Open links that fit in a space",
                 about: "The kind is read from the match unless --kind says it: a site, exactly a host, the start of an address, words in it, a pattern with *, or a regular expression. A rule for a site goes before broader ones, and the others go last. A rule that hands links to another app or browser is the person's to make, so --app answers person_only with the place. broadway settings set links.open SPACE sends every other link from outside to a space.",
                 examples: ["broadway links add github.com --space Work", "broadway links add /pull/ --kind contains --space Reviews"]),
            Verb("links move <id> <position>", "Move a rule among the others", about: "Position 1 is first, and the first rule that fits wins"),
            Verb("links delete <id>", "Delete a rule"),
        ]),
        Noun("keywords", "Site shortcuts: a word before a search sends it to a site", group: "Settings", [
            Verb("keywords list", "List the site shortcuts", columns: ["keyword", "site", "address"]),
            Verb("keywords add <keyword> <address>", "Add a site shortcut", about: "The address is http or https with one %s where the words go. A word that already goes somewhere is the person's to change.",
                 examples: ["broadway keywords add yt 'https://www.youtube.com/results?search_query=%s'"]),
            Verb("keywords delete <keyword>", "Delete a site shortcut"),
        ]),
        Noun("actions", "Quick Actions: short names in the address field that open something new", group: "Settings", [
            Verb("actions list", "List the Quick Actions in their order", columns: ["id", "short", "name", "address"]),
            Verb("actions add <short> <address> [--name TEXT]", "Add a Quick Action", about: "Typing the short name in the address field opens the address. A short name that already opens something is the person's to change.",
                 examples: ["broadway actions add pr github.com/pulls --name \"My pull requests\""]),
            Verb("actions rename <action> <name>", "Rename a Quick Action", about: "By id or short name"),
            Verb("actions move <action> <position>", "Move a Quick Action among the others", about: "Position 1 is first"),
            Verb("actions delete <action>", "Delete a Quick Action", about: "New document and New meeting come back from Settings › Field › Quick Actions"),
        ]),
        Noun("snippets", "Snippets: your own text, offered when you type ;keyword in a field", group: "Settings", [
            Verb("snippets list", "List the snippets", columns: ["keyword", "title", "line"]),
            Verb("snippets add <keyword> <text> [--title TEXT]", "Add a snippet", about: "{date}, {time}, {clipboard} and {cursor} fill in when it is used. The title is the keyword unless --title gives one.",
                 examples: ["broadway snippets add sig 'Best, Sam' --title Signature"]),
            Verb("snippets rename <keyword> <title>", "Change a snippet's title"),
            Verb("snippets delete <keyword>", "Delete a snippet"),
        ]),
        Noun("extensions", "Extensions", group: "Settings", [
            Verb("extensions list", "List extensions", columns: ["id", "name", "version", "enabled"]),
            Verb("extensions show <id>", "One extension"),
            Verb("extensions enable <id>", "Turn an extension on"),
            Verb("extensions disable <id>", "Turn an extension off"),
            Verb("extensions reload <id>", "Reload an extension"),
            Verb("extensions remove <id>", "Remove an extension"),
            Verb("extensions install <link>", "Install an extension, asking the person", about: "Broadway asks the person there, showing what it wants"),
            Verb("extensions private <id>", "Only the person can allow an extension in private windows", hidden: true),
        ]),
        Noun("shields", "The ad and tracker blocker", group: "Settings", [
            Verb("shields list", "Say what's on, and where it's off", columns: ["site"]),
            Verb("shields on <host>", "Turn the blocker back on for a site"),
            Verb("shields off <host>", "Only the person can turn it off", hidden: true),
            Verb("shields update", "Fetch the filter lists now"),
        ]),
        Noun("permissions", "What sites were allowed or refused", group: "Settings", [
            Verb("permissions list [site]", "List site permissions", columns: ["site", "kind", "allowed"]),
            Verb("permissions reset <site> [--kind KIND]", "Forget an answer, so the site has to ask again"),
            Verb("permissions allow <site>", "Only the person can allow a site", hidden: true),
        ]),
        Noun("hooks", "Programs of the person's own that decide links, downloads and site requests", group: "Settings", [
            Verb("hooks list", "List hooks: each one's event, program, switch and last result", columns: ["id", "event", "program", "on", "result"]),
        ]),
        Noun("skills", "What Broadway knows about working on sites", group: "AI", [
            Verb("skills list [--url URL]", "List skills", columns: ["name", "yours", "about"]),
            Verb("skills show <name>", "Read a skill"),
            Verb("skills new [file]", "Add a skill from a file or stdin", fromStdin: true),
            Verb("skills duplicate <name>", "Make your own copy of a skill"),
            Verb("skills delete <name>", "Delete one of your skills"),
        ]),
        Noun("replies", "Threads watched for a reply", group: "AI", [
            Verb("replies list", "List watched threads", columns: ["id", "state", "title", "url"]),
            Verb("replies stop <id>", "Stop watching a thread"),
        ]),
        Noun("now", "The rows under Now", group: "AI", [
            Verb("now list", "List the rows", columns: ["id", "title", "detail"]),
            Verb("now done <id>", "Mark a row done"),
        ]),
        Noun("agents", "Agents connected to Broadway, and what they may do", group: "AI", first: "status", [
            Verb("agents status", "The switch, the mode, the site rules and this agent's session", about: "Only the person can change the switch, the mode and the sites, in Settings › Agents"),
            Verb("agents connect [--name TEXT]", "Start this agent's session: a card of its own in Broadway's sidebar",
                 about: "Optional: the first command that opens or works in a tab starts it too. The name defaults to the program that ran broadway, such as Claude Code.",
                 examples: ["broadway agents connect --name \"Claude Code\""]),
            Verb("agents list", "Connected and finished agent sessions", columns: ["id", "name", "state", "tabs", "status"]),
            Verb("agents done [--summary TEXT] [--failed] [--close] [--keep]", "End this agent's session with a line for the person",
                 about: "The card shows a tick, or a downcast face with --failed, and the summary. Your tabs close. The one the person is looking at becomes theirs. --keep asks the person once and gives them all of yours if they say yes, and they close if not. A tab with a form not sent, a download, sound or a window still open closes once that is over, or becomes the person's after 20 minutes. --close is still accepted and changes nothing.",
                 examples: ["broadway agents done --summary \"Opened the three pull requests that need you\"", "broadway agents done --keep --summary \"Found the order\""]),
            Verb("agents idle [--summary TEXT] [--hook AGENT]", "Say this agent's turn is over, so its card reads finished until its next command",
                 about: "Its tabs stay as they are and the session goes on, until 20 minutes without a command end it and close its tabs. The next command makes it working again. A summary takes the place of the last thing it did. With --hook claude or --hook codex it reads a Stop or SessionEnd hook's event on stdin, never starts Broadway, prints nothing and always exits 0. broadway setup adds those hooks.",
                 examples: ["broadway agents idle --summary \"Waiting for your answer about the dates\""]),
            Verb("agents disconnect [id] [--summary TEXT] [--failed]", "End a session: this agent's, or another's by id",
                 about: "Its tabs close as with agents done. Ending another agent's session needs the person's yes."),
        ]),
        Noun("approvals", "What waits for the person's yes", group: "AI", [
            Verb("approvals list", "List what waits", about: "Only the person can answer, in Broadway", columns: ["title", "site", "task"]),
        ]),
    ]

    static let aliases: [String: (noun: String, verb: String)] = [
        "zoom": ("page", "zoom"), "pdf": ("page", "pdf"), "translate": ("page", "translate"),
        "back": ("page", "back"), "forward": ("page", "forward"), "reload": ("page", "reload"),
    ]

    static let nounAliases = ["agent": "agents"]

    static func noun(_ word: String) -> Noun? {
        let name = nounAliases[word] ?? word
        return all.first { $0.name == name }
    }

    static var names: [String] { all.map(\.name) + aliases.keys.sorted() }

    static func route(_ words: [String]) throws -> (noun: Noun, verb: Verb, rest: [String])? {
        guard let first = words.first else { return nil }
        if first == "fill", words.dropFirst().first?.hasPrefix("{") == true { return nil }
        if let alias = aliases[first], let noun = noun(alias.noun), let verb = noun.verb(alias.verb) {
            return (noun, verb, Array(words.dropFirst()))
        }
        guard let noun = noun(first) else { return nil }
        let rest = Array(words.dropFirst())
        if let second = rest.first, let verb = noun.verb(second) {
            return (noun, verb, Array(rest.dropFirst()))
        }
        if let second = rest.first, !second.hasPrefix("-"), !noun.loose, noun.name != "space" {
            let near = Near.best(second, in: noun.names).map { "Did you mean \(noun.name) \($0)?" }
            throw Failure.usage("\(noun.name) has no \(second)", hint: near ?? "\(noun.name): \(noun.names.joined(separator: ", ")).")
        }
        guard let first = noun.first, let verb = noun.verb(first) else {
            throw Failure.usage("\(noun.name) needs a verb: \(noun.names.joined(separator: ", "))", hint: "Run broadway help \(noun.name)")
        }
        return (noun, verb, rest)
    }
}
