import Darwin
import Foundation

struct Check {
    var name: String
    var ok: Bool
    var required: Bool
    var detail: String
    var fix: String?
    var absent = false

    var object: [String: Any] {
        var found: [String: Any] = ["name": name, "ok": ok, "required": required, "detail": detail]
        if let fix { found["fix"] = fix }
        if absent { found["absent"] = true }
        return found
    }
}

struct Step {
    var part: String
    var done: Bool
    var path: String
    var note: String

    var object: [String: Any] { ["part": part, "done": done, "path": path, "note": note] }
}

public enum Setup {
    static let parts = ["command", "completions", "claude", "codex", "cursor", "opencode", "gemini"]
    static let others = ["cursor", "opencode", "gemini"]
    static let opening = "# >>> broadway >>>"
    static let closing = "# <<< broadway <<<"
    static let mark = "written by broadway setup"

    static let guideVersion = "0.4"
    static let codexToolTimeout = 900

    static let skill = """
    ---
    name: broadway
    description: >
      Broadway is the person's own web browser on this Mac, signed in to their sites, driven with the broadway
      command. Use it for anything on the web: opening and reading pages, filling forms, clicking through
      sites, screenshots, their open tabs and browsing history. Run broadway guide first.
    managed-by: \(mark)
    broadway-guide: \(guideVersion)
    ---

    Run `broadway guide` before the first browser step. It is short and always matches the installed Broadway.

        broadway open https://example.com     # a tab of your own. go URL moves the tab you are in
        broadway click "Sign in"              # by words or @ref, answers with what changed
        broadway agents done --summary "…"    # always, at the end

    """

    static let madeFolder = "broadway-made: skills"

    static func sharedSkill(made: Bool) -> String {
        skill.replacingOccurrences(of: "managed-by: \(mark)\nbroadway-guide: \(guideVersion)\n",
                                   with: "metadata:\n  managed-by: \(mark)\n  broadway-guide: \"\(guideVersion)\"\n" + (made ? "  \(madeFolder)\n" : ""))
    }

    static func skill(for part: String, made: Bool) -> String {
        if others.contains(part) { return sharedSkill(made: made) }
        guard made else { return skill }
        return skill.replacingOccurrences(of: "broadway-guide: \(guideVersion)\n", with: "broadway-guide: \(guideVersion)\n\(madeFolder)\n")
    }

    private static func madeSkills(_ file: String) -> Bool {
        let skills = ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return !exists(skills) || (ours(file) && text(file)?.contains(madeFolder) == true)
    }

    private static func takeSkill(_ file: String, part: String) -> Step {
        let made = ours(file) && text(file)?.contains(madeFolder) == true
        let step = take(file, part: part)
        let folder = (file as NSString).deletingLastPathComponent
        rmdir(folder)
        if made { rmdir((folder as NSString).deletingLastPathComponent) }
        return step
    }

    static func guide(in text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("broadway-guide:") {
                return trimmed.dropFirst("broadway-guide:".count).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            }
        }
        return nil
    }

    static func older(_ found: String?, than wanted: String = guideVersion) -> Bool {
        guard let found, !found.isEmpty else { return true }
        let have = found.split(separator: ".").map { Int($0) ?? 0 }
        let want = wanted.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(have.count, want.count) {
            let a = index < have.count ? have[index] : 0
            let b = index < want.count ? want[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public struct Paths {
        public var home: String

        public init(home: String) {
            self.home = home
        }

        var link: String { home + "/.local/bin/broadway" }
        var fish: String { home + "/.config/fish/completions/broadway.fish" }
        var zsh: String { home + "/.local/share/broadway/broadway.zsh" }
        var zshrc: String { home + "/.zshrc" }
        var bash: String { home + "/.local/share/bash-completion/completions/broadway" }
        var claude: String { home + "/.claude" }
        var codex: String { home + "/.codex" }
        var claudeSkill: String { claude + "/skills/broadway/SKILL.md" }
        var codexSkill: String { codex + "/skills/broadway/SKILL.md" }
        var cursor: String { home + "/.cursor" }
        var opencode: String { home + "/.config/opencode" }
        var gemini: String { home + "/.gemini" }
        var cursorSkill: String { cursor + "/skills/broadway/SKILL.md" }
        var opencodeSkill: String { opencode + "/skills/broadway/SKILL.md" }
        var geminiSkill: String { gemini + "/skills/broadway/SKILL.md" }

        public func folder(_ part: String) -> String {
            switch part {
            case "claude": claude
            case "codex": codex
            case "cursor": cursor
            case "opencode": opencode
            default: gemini
            }
        }

        func skill(_ part: String) -> String { folder(part) + "/skills/broadway/SKILL.md" }
        var codexConfig: String { codex + "/config.toml" }
        var claudeSettings: String { claude + "/settings.json" }
        var codexHooks: String { codex + "/hooks.json" }

        func hooks(_ part: String) -> String { part == "claude" ? claudeSettings : codexHooks }
    }

    static func codexTimeout(_ config: String) -> String? {
        var lines = config.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { ["[mcp_servers.broadway]", "[mcp_servers.\"broadway\"]"].contains($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        let end = lines[(header + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        let wanted = "tool_timeout_sec = \(codexToolTimeout)"
        if let found = lines[(header + 1)..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("tool_timeout_sec") }) {
            let value = lines[found].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard (Double(value) ?? 0) < Double(codexToolTimeout) else { return nil }
            lines[found] = wanted
        } else {
            lines.insert(wanted, at: header + 1)
        }
        return lines.joined(separator: "\n")
    }

    static func version(binary: String) -> String? {
        guard let bundle = Place.bundle(of: binary),
              let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private static var files: FileManager { .default }

    private static func exists(_ path: String) -> Bool { files.fileExists(atPath: path) }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func ours(_ path: String) -> Bool { text(path)?.contains(mark) == true }

    static func cursorReadsElsewhere(_ paths: Paths) -> String? {
        if ours(paths.claudeSkill) { return "~/.claude/skills" }
        if ours(paths.codexSkill) { return "~/.codex/skills" }
        return nil
    }

    private static func put(_ content: String, at path: String) throws {
        try files.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func write(_ content: String, at path: String, part: String) -> Step {
        if exists(path), !ours(path) { return Step(part: part, done: false, path: path, note: "left alone: this file isn't broadway's") }
        do {
            try put(content, at: path)
            return Step(part: part, done: true, path: path, note: "")
        } catch {
            return Step(part: part, done: false, path: path, note: error.localizedDescription)
        }
    }

    private static func through(_ content: String, at path: String) throws {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let kept = (try? files.attributesOfItem(atPath: real.path)[.posixPermissions]) as? NSNumber
        try put(content, at: real.path)
        if let kept { try? files.setAttributes([.posixPermissions: kept], ofItemAtPath: real.path) }
    }

    static func addHooks(_ part: String, paths: Paths) -> Step {
        let file = paths.hooks(part)
        let note = "added broadway's Stop and SessionEnd hooks"
        guard exists(file) else {
            do {
                try put(HookSetup.fresh(part), at: file)
                return Step(part: part, done: true, path: file, note: note)
            } catch {
                return Step(part: part, done: false, path: file, note: error.localizedDescription)
            }
        }
        guard let here = text(file) else { return Step(part: part, done: false, path: file, note: "left alone: it couldn't be read") }
        switch HookSetup.adding(part, to: here) {
        case .same:
            return Step(part: part, done: true, path: file, note: "hooks already there")
        case .foreign(let why):
            return Step(part: part, done: false, path: file, note: why)
        case .changed(let made):
            do {
                try through(made, at: file)
                return Step(part: part, done: true, path: file, note: note)
            } catch {
                return Step(part: part, done: false, path: file, note: error.localizedDescription)
            }
        }
    }

    static func takeHooks(_ part: String, paths: Paths) -> Step {
        let file = paths.hooks(part)
        guard exists(file), let here = text(file) else { return Step(part: part, done: false, path: file, note: "not there") }
        switch HookSetup.removing(part, from: here) {
        case .same:
            return Step(part: part, done: false, path: file, note: "no hooks of broadway's")
        case .foreign(let why):
            return Step(part: part, done: false, path: file, note: why)
        case .changed(let made):
            do {
                if made == HookSetup.emptied {
                    try files.removeItem(atPath: URL(fileURLWithPath: file).resolvingSymlinksInPath().path)
                    if (try? files.destinationOfSymbolicLink(atPath: file)) != nil { try? files.removeItem(atPath: file) }
                } else {
                    try through(made, at: file)
                }
                return Step(part: part, done: true, path: file, note: "took out broadway's hooks")
            } catch {
                return Step(part: part, done: false, path: file, note: error.localizedDescription)
            }
        }
    }

    private static func link(_ paths: Paths, to binary: String) -> Step {
        let path = paths.link
        guard binary.contains(".app/Contents/Helpers/") else {
            return Step(part: "command", done: false, path: path, note: "this copy of broadway isn't inside Broadway.app")
        }
        if let held = try? files.attributesOfItem(atPath: path)[.type] as? FileAttributeType, held != .typeSymbolicLink {
            return Step(part: "command", done: false, path: path, note: "left alone: something else is there")
        }
        if (try? files.destinationOfSymbolicLink(atPath: path)) != nil { try? files.removeItem(atPath: path) }
        do {
            try files.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: path, withDestinationPath: binary)
            return Step(part: "command", done: true, path: path, note: "")
        } catch {
            return Step(part: "command", done: false, path: path, note: error.localizedDescription)
        }
    }

    static func zshBlock(paths: Paths) -> String {
        """
        \(opening)
        (( $+functions[compdef] )) && [ -r "\(paths.zsh)" ] && source "\(paths.zsh)"
        \(closing)

        """
    }

    static func adding(block: String, to content: String) -> String {
        guard !content.contains(opening) else { return content }
        return content + (content.isEmpty || content.hasSuffix("\n") ? "" : "\n") + block
    }

    static func removing(from content: String) -> String {
        guard let start = content.range(of: opening), let end = content.range(of: closing, range: start.upperBound..<content.endIndex) else { return content }
        var tail = end.upperBound
        if tail < content.endIndex, content[tail] == "\n" { tail = content.index(after: tail) }
        return String(content[..<start.lowerBound]) + String(content[tail...])
    }

    private static func completions(_ paths: Paths) -> [Step] {
        var steps = [write(Completions.fish, at: paths.fish, part: "fish"),
                     write(Completions.bash, at: paths.bash, part: "bash")]
        guard exists(paths.zshrc) else { return steps + [Step(part: "zsh", done: false, path: paths.zshrc, note: "skipped: no .zshrc")] }
        let script = write(Completions.zsh, at: paths.zsh, part: "zsh")
        steps.append(script)
        if script.done, let content = text(paths.zshrc) {
            let changed = adding(block: zshBlock(paths: paths), to: content)
            if changed != content { try? put(changed, at: paths.zshrc) }
        }
        return steps
    }

    private static func skills(_ paths: Paths, wanted: [String]) -> [Step] {
        var steps: [Step] = []
        for (part, folder, file) in [("claude", paths.claude, paths.claudeSkill), ("codex", paths.codex, paths.codexSkill)] where wanted.contains(part) {
            guard exists(folder) else {
                steps.append(Step(part: part, done: false, path: file, note: "skipped: \(folder) isn't here"))
                continue
            }
            steps.append(write(skill(for: part, made: madeSkills(file)), at: file, part: part))
            steps.append(addHooks(part, paths: paths))
            if part == "codex", let config = text(paths.codexConfig), let changed = codexTimeout(config) {
                let done = (try? put(changed, at: paths.codexConfig)) != nil
                steps.append(Step(part: part, done: done, path: paths.codexConfig, note: done ? "gave broadway's MCP entry a \(codexToolTimeout) s tool timeout" : "couldn't write it"))
            }
        }
        for part in others where wanted.contains(part) {
            let folder = paths.folder(part)
            let file = paths.skill(part)
            guard exists(folder) else {
                steps.append(Step(part: part, done: false, path: file, note: "skipped: \(folder) isn't here"))
                continue
            }
            if part == "cursor", !exists(file), let elsewhere = cursorReadsElsewhere(paths) {
                steps.append(Step(part: part, done: false, path: file, note: "skipped: Cursor reads broadway's skill in \(elsewhere)"))
                continue
            }
            steps.append(write(sharedSkill(made: madeSkills(file)), at: file, part: part))
        }
        return steps
    }

    static func install(_ wanted: [String], paths: Paths, binary: String) -> [Step] {
        var steps: [Step] = []
        if wanted.contains("command") { steps.append(link(paths, to: binary)) }
        if wanted.contains("completions") { steps += completions(paths) }
        return steps + skills(paths, wanted: wanted)
    }

    static func refresh(_ wanted: [String], paths: Paths) -> [Step] {
        var steps: [Step] = []
        for part in ["claude", "codex"] + others where wanted.contains(part) {
            let file = paths.skill(part)
            guard let here = text(file) else {
                steps.append(Step(part: part, done: false, path: file, note: "not there"))
                continue
            }
            guard here.contains("managed-by: \(mark)") else {
                steps.append(Step(part: part, done: false, path: file, note: "left alone: this file isn't broadway's"))
                continue
            }
            steps.append(older(guide(in: here)) ? write(skill(for: part, made: here.contains(madeFolder)), at: file, part: part) : Step(part: part, done: false, path: file, note: "up to date"))
            if !others.contains(part) { steps.append(updateHooks(part, paths: paths)) }
        }
        return steps
    }

    static func updateHooks(_ part: String, paths: Paths) -> Step {
        let file = paths.hooks(part)
        let missing = Step(part: part, done: false, path: file, note: "no hooks of broadway's here, and broadway setup \(part) adds them")
        guard exists(file), let here = text(file) else { return missing }
        switch HookSetup.refreshing(part, in: here) {
        case .same:
            return HookSetup.present(part, in: here) ? Step(part: part, done: false, path: file, note: "hooks up to date") : missing
        case .foreign(let why):
            return Step(part: part, done: false, path: file, note: why)
        case .changed(let made):
            do {
                try through(made, at: file)
                return Step(part: part, done: true, path: file, note: "brought broadway's hooks up to date")
            } catch {
                return Step(part: part, done: false, path: file, note: error.localizedDescription)
            }
        }
    }

    private static func take(_ path: String, part: String) -> Step {
        guard exists(path) else { return Step(part: part, done: false, path: path, note: "not there") }
        guard ours(path) else { return Step(part: part, done: false, path: path, note: "left alone: this file isn't broadway's") }
        try? files.removeItem(atPath: path)
        return Step(part: part, done: !exists(path), path: path, note: "")
    }

    static func uninstall(_ wanted: [String], paths: Paths) -> [Step] {
        var steps: [Step] = []
        if wanted.contains("command") {
            if let target = try? files.destinationOfSymbolicLink(atPath: paths.link) {
                if target.hasSuffix("/Contents/Helpers/broadway") {
                    try? files.removeItem(atPath: paths.link)
                    steps.append(Step(part: "command", done: true, path: paths.link, note: ""))
                } else {
                    steps.append(Step(part: "command", done: false, path: paths.link, note: "left alone: it points somewhere else"))
                }
            } else {
                steps.append(Step(part: "command", done: false, path: paths.link, note: exists(paths.link) ? "left alone: something else is there" : "not there"))
            }
        }
        if wanted.contains("completions") {
            steps.append(take(paths.fish, part: "fish"))
            steps.append(take(paths.bash, part: "bash"))
            steps.append(take(paths.zsh, part: "zsh"))
            if let content = text(paths.zshrc) {
                let changed = removing(from: content)
                if changed != content { try? put(changed, at: paths.zshrc) }
            }
        }
        if wanted.contains("claude") {
            steps.append(takeSkill(paths.claudeSkill, part: "claude"))
            steps.append(takeHooks("claude", paths: paths))
        }
        if wanted.contains("codex") {
            steps.append(takeSkill(paths.codexSkill, part: "codex"))
            steps.append(takeHooks("codex", paths: paths))
        }
        for part in others where wanted.contains(part) {
            steps.append(takeSkill(paths.skill(part), part: part))
        }
        return steps
    }

    static func onPath(_ folder: String, environment: [String: String]) -> Bool {
        (environment["PATH"] ?? "").split(separator: ":").contains { $0 == folder || $0 == folder + "/" }
    }

    static func checks(paths: Paths, binary: String, environment: [String: String], status: [String: Any]?, running: Bool) -> [Check] {
        var found: [Check] = []
        let inApp = binary.contains(".app/Contents/Helpers/")
        found.append(Check(name: "app", ok: inApp, required: true, detail: inApp ? Place.bundle(of: binary) ?? "" : "this broadway isn't inside Broadway.app: \(binary)",
                           fix: inApp ? nil : "Run the copy at Broadway.app/Contents/Helpers/broadway"))
        let target = try? files.destinationOfSymbolicLink(atPath: paths.link)
        let linked = target != nil && exists(target ?? "")
        found.append(Check(name: "command", ok: linked, required: true,
                           detail: linked ? "\(paths.link) → \(target ?? "")" : target != nil ? "\(paths.link) points at something gone" : "\(paths.link) isn't there",
                           fix: linked ? nil : "Run broadway setup command"))
        let folder = (paths.link as NSString).deletingLastPathComponent
        let reachable = onPath(folder, environment: environment)
        found.append(Check(name: "path", ok: reachable, required: true, detail: reachable ? "\(folder) is on PATH" : "\(folder) isn't on PATH",
                           fix: reachable ? nil : "fish: fish_add_path ~/.local/bin   zsh or bash: export PATH=\"$HOME/.local/bin:$PATH\""))
        found.append(Check(name: "running", ok: running, required: false, detail: running ? "Broadway is answering" : "Broadway isn't running. A browser command starts it hidden.", fix: nil))
        if running {
            let agents = status?["agents"] as? Bool == true
            found.append(Check(name: "agents", ok: agents, required: false, detail: agents ? "agents are on" : "agents are off: page commands and tasks are refused",
                               fix: agents ? nil : Failure.hints["agents_off"]))
            if let app = status?["version"] as? String, let mine = version(binary: binary) {
                found.append(Check(name: "version", ok: app == mine, required: false, detail: app == mine ? "broadway and Broadway are both \(mine)" : "broadway is \(mine), Broadway is \(app)",
                                   fix: app == mine ? nil : "Restart Broadway"))
            }
            let plans = status?["plans"] as? [String: [String: Any]] ?? [:]
            let connected = plans.values.contains { $0["connected"] as? Bool == true }
            found.append(Check(name: "plan", ok: connected, required: false, detail: connected ? "a plan is connected for tasks" : "no plan is connected: tasks won't run",
                               fix: connected ? nil : "Install Claude Code or Codex and sign in"))
        }
        func file(_ name: String, _ path: String, _ want: String, wantedHere: Bool, fix: String) {
            guard wantedHere else {
                found.append(Check(name: name, ok: true, required: false, detail: "not used here", fix: nil))
                return
            }
            let here = text(path)
            let good = here?.contains(want) == true && ours(path)
            found.append(Check(name: name, ok: good, required: false, detail: good ? path : here == nil ? "\(path) isn't there" : "\(path) is out of date or isn't broadway's", fix: good ? nil : fix))
        }
        file("fish", paths.fish, "__complete", wantedHere: true, fix: "Run broadway setup completions")
        file("bash", paths.bash, "__complete", wantedHere: true, fix: "Run broadway setup completions")
        file("zsh", paths.zsh, "__complete", wantedHere: exists(paths.zshrc), fix: "Run broadway setup completions")
        func skill(_ name: String, _ path: String, wantedHere: Bool) {
            guard wantedHere else {
                found.append(Check(name: name, ok: true, required: false, detail: "not used here", fix: nil))
                return
            }
            let fix = "Run broadway setup \(name)"
            guard let here = text(path) else {
                found.append(Check(name: name, ok: false, required: false, detail: "\(path) isn't there", fix: fix, absent: true))
                return
            }
            guard here.contains("name: broadway"), ours(path) else {
                found.append(Check(name: name, ok: false, required: false, detail: "\(path) isn't broadway's", fix: fix))
                return
            }
            let stale = older(guide(in: here))
            found.append(Check(name: name, ok: !stale, required: false, detail: stale ? "\(path) is out of date" : path, fix: stale ? fix : nil))
        }
        skill("claude", paths.claudeSkill, wantedHere: exists(paths.claude))
        skill("codex", paths.codexSkill, wantedHere: exists(paths.codex))
        if exists(paths.cursor), !exists(paths.cursorSkill), let elsewhere = cursorReadsElsewhere(paths) {
            found.append(Check(name: "cursor", ok: true, required: false, detail: "Cursor reads broadway's skill in \(elsewhere)", fix: nil))
        } else {
            skill("cursor", paths.cursorSkill, wantedHere: exists(paths.cursor))
        }
        skill("opencode", paths.opencodeSkill, wantedHere: exists(paths.opencode))
        skill("gemini", paths.geminiSkill, wantedHere: exists(paths.gemini))
        for part in ["claude", "codex"] {
            let name = part + " hooks"
            guard text(part == "claude" ? paths.claudeSkill : paths.codexSkill)?.contains("managed-by: \(mark)") == true else {
                found.append(Check(name: name, ok: true, required: false, detail: "not used here", fix: nil))
                continue
            }
            let file = paths.hooks(part)
            let good = text(file).map { HookSetup.installed(part, in: $0) } == true
            found.append(Check(name: name, ok: good, required: false,
                               detail: good ? "\(file) tells Broadway when a turn or a session ends" : "\(file) has no hooks of broadway's, so a finished turn shows only after a quiet time",
                               fix: good ? nil : "Run broadway setup \(part)"))
        }
        return found
    }
}

extension Builtins {
    private static func wanted(_ words: [String], verb: String) throws -> [String] {
        for word in words where !Setup.parts.contains(word) {
            let near = Near.best(word, in: Setup.parts).map { "Did you mean \($0)?" }
            throw Failure.usage("\(verb) has no \(word)", hint: near ?? "It takes \(Setup.parts.joined(separator: ", "))")
        }
        return words.isEmpty ? Setup.parts : words
    }

    private static func report(_ steps: [Step], verb: String, context: Context) -> Exit {
        let console = context.console
        if !console.json {
            for step in steps {
                let mark = step.done ? console.out.good("ok  ") : console.out.dim("--  ")
                console.line(mark + Plain.pad(step.part, 13) + step.path + (step.note.isEmpty ? "" : console.out.dim("  " + step.note)))
            }
        }
        console.success(verb, ["steps": steps.map(\.object)])
        return .done
    }

    static let setupCommands: [Builtin] = [
        Builtin(name: "setup", usage: "broadway setup [command] [completions] [claude] [codex] [cursor] [opencode] [gemini] [--refresh]", summary: "Put broadway on your PATH, with completions and agent skills", group: "Setup",
                details: "Links ~/.local/bin/broadway to this app's copy, writes fish, bash and zsh completions, and installs a skill for Claude Code and Codex where they are present, and for Cursor, opencode and Gemini CLI in their own skills folders when their folders are there. Cursor gets no copy of its own when it already reads broadway's skill in ~/.claude/skills or ~/.codex/skills. The skill is short and sends agents to broadway guide. It also adds a Stop and a SessionEnd hook, in ~/.claude/settings.json and ~/.codex/hooks.json, that run broadway agents idle --hook so the agent's card reads finished when its turn ends. It adds only its own entries and keeps the rest of each file as it was. It leaves files that aren't its own alone. broadway remove undoes it. Broadway runs this by itself when agents are turned on, and again for an agent it finds for the first time. When nothing is at ~/.local/bin/broadway, the run when agents are turned on also links the command there, unless Broadway is running from its disk image or a download folder. It never moves or replaces what is already there.\n--refresh  only rewrite skills broadway wrote that are older than this Broadway, and bring broadway's own hook entries up to date where they are already there. It creates no skill and adds no hook. Broadway runs it at each launch.",
                examples: ["broadway setup", "broadway setup completions", "broadway setup claude codex --refresh"]) { context, words in
            let refreshing = words.contains("--refresh")
            let parts = try wanted(words.filter { $0 != "--refresh" }, verb: "setup")
            let paths = Setup.Paths(home: context.home)
            if refreshing { return report(Setup.refresh(parts, paths: paths), verb: "setup", context: context) }
            return report(Setup.install(parts, paths: paths, binary: context.binary), verb: "setup", context: context)
        },
        Builtin(name: "remove", usage: "broadway remove [command] [completions] [claude] [codex] [cursor] [opencode] [gemini]", summary: "Undo broadway setup", group: "Setup",
                examples: ["broadway remove", "broadway remove codex"]) { context, words in
            report(Setup.uninstall(try wanted(words, verb: "remove"), paths: Setup.Paths(home: context.home)), verb: "remove", context: context)
        },
        Builtin(name: "doctor", usage: "broadway doctor", summary: "Check each piece of the setup and say what is wrong", group: "Setup",
                details: "It never starts Broadway. Exits 1 if something broadway can't work without is wrong.",
                examples: ["broadway doctor", "broadway doctor --json"]) { context, _ in
            let link = context.place.connect()
            var status: [String: Any]?
            if let link, link.send(["op": "status"]) { status = link.object() }
            let checks = Setup.checks(paths: Setup.Paths(home: context.home), binary: context.binary, environment: context.environment,
                                      status: status, running: status != nil)
            let console = context.console
            if !console.json {
                let wide = (checks.map(\.name.count).max() ?? 0) + 2
                for check in checks {
                    let mark = check.ok ? console.out.good("ok  ") : check.required ? console.out.bad("fail") : console.out.warn("warn")
                    console.line("\(mark)  \(Plain.pad(check.name, wide))\(check.detail)")
                    if let fix = check.fix { console.line(String(repeating: " ", count: wide + 6) + console.out.dim(fix)) }
                }
            }
            let data: [String: Any] = ["checks": checks.map(\.object)]
            if let broken = checks.first(where: { $0.required && !$0.ok }) {
                throw Failure("not_set_up", "\(broken.name): \(broken.detail)", hint: broken.fix, data: data)
            }
            console.success("doctor", data)
            return .done
        },
    ]
}
