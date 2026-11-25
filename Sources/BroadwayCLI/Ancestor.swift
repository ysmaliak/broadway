import Foundation

public struct AgentAncestor: Equatable {
    public let pid: Int32
    public let started: Int64
    public let name: String

    public struct Process: Equatable {
        public let parent: Int32
        public let name: String
        public let started: Int64

        public init(parent: Int32, name: String, started: Int64) {
            self.parent = parent
            self.name = name
            self.started = started
        }
    }

    static let passedOver: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh", "dash", "ksh", "tcsh", "csh",
                                          "env", "login", "sudo", "timeout", "gtimeout", "xargs", "nohup", "time", "caffeinate",
                                          "script", "tmux", "screen", "nice", "make", "npx", "npm", "bunx", "uv", "pnpm"]

    public static func find(from start: Int32, lookup: (Int32) -> Process?) -> AgentAncestor? {
        var pid = start
        var seen: Set<Int32> = []
        while pid > 1, seen.insert(pid).inserted, let found = lookup(pid) {
            let base = (found.name as NSString).lastPathComponent
            if !passedOver.contains(head(base)), !(base.lowercased() == "node" && lookup(found.parent).map(\.name).map(isAgent) == true) {
                return AgentAncestor(pid: pid, started: found.started, name: base)
            }
            pid = found.parent
        }
        return nil
    }

    public static func head(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent.lowercased()
        return base.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? base
    }

    static let launchers: [String: String] = ["sshd": "SSH", "sshd-session": "SSH", "mosh-server": "Mosh",
                                              "et": "Eternal Terminal", "etserver": "Eternal Terminal", "etterminal": "Eternal Terminal"]

    public static let carriers: Set<String> = ["ssh", "sshd", "sshd-session"]

    public static func carrier(_ name: String) -> Bool {
        carriers.contains(head(name))
    }

    public static func forwarded(_ said: [String: Any], host: String?) -> [String: Any] {
        var out = said
        out["pid"] = nil
        out["started"] = nil
        out["direct"] = false
        if let host, !host.isEmpty { out["host"] = host }
        return out
    }

    public static func hostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(cString: buffer)
        let short = name.hasSuffix(".local") ? String(name.dropLast(6)) : name
        return short.isEmpty ? nil : short
    }

    static func plain(_ name: String) -> String {
        launchers[head(name)] ?? name
    }

    public static func remote(environment: [String: String], found: AgentAncestor?) -> (id: String, name: String)? {
        guard let address = environment["SSH_CONNECTION"]?.split(separator: " ").first.map(String.init), !address.isEmpty else { return nil }
        let kind: String? = if let found { launchers[head(found.name)] } else { "SSH" }
        guard let kind, kind != "Eternal Terminal" else { return nil }
        return ("ssh:\(address)", "\(kind) from \(address)")
    }

    static func isAgent(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent.lowercased()
        return ["claude", "codex", "cursor", "windsurf", "opencode", "gemini"].contains { base.hasPrefix($0) }
    }

    public static func current() -> AgentAncestor? {
        find(from: getppid(), lookup: process)
    }

    public static func process(_ pid: Int32) -> Process? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let time = info.kp_proc.p_un.__p_starttime
        return Process(parent: info.kp_eproc.e_ppid, name: named(arguments: arguments(pid), path: fullName(pid), command: command),
                       started: Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec))
    }

    static let interpreters: Set<String> = ["node", "bun", "deno"]

    public static func named(arguments: [String], path: String?, command: String) -> String {
        let first = arguments.first.map { ($0.components(separatedBy: ": ").first ?? $0) as NSString }.map(\.lastPathComponent) ?? ""
        let name = !first.isEmpty ? first : path.map { ($0 as NSString).lastPathComponent } ?? command
        guard interpreters.contains(name.lowercased()) else { return name }
        let script = arguments.dropFirst().first { !$0.hasPrefix("-") }?.lowercased() ?? ""
        let base = (script as NSString).lastPathComponent
        if script.contains("claude-code") || base == "claude" || base == "claude.js" { return "claude" }
        if script.contains("@openai/codex") || base == "codex" || base == "codex.js" { return "codex" }
        if script.contains("gemini-cli") || base == "gemini" { return "gemini" }
        if script.contains("opencode") || base == "opencode" { return "opencode" }
        return name
    }

    static func arguments(_ pid: Int32) -> [String] {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        return parse(Array(buffer.prefix(size)))
    }

    static func parse(_ raw: [UInt8]) -> [String] {
        guard raw.count > 4 else { return [] }
        let count = raw.prefix(4).withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = 4
        while index < raw.count, raw[index] != 0 { index += 1 }
        while index < raw.count, raw[index] == 0 { index += 1 }
        var found: [String] = []
        while found.count < min(count, 4), index < raw.count {
            let start = index
            while index < raw.count, raw[index] != 0 { index += 1 }
            found.append(String(decoding: raw[start..<index], as: UTF8.self))
            index += 1
        }
        return found
    }

    static func fullName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }

    public static func session(_ environment: [String: String]) -> String? {
        for (key, kind) in [("CLAUDE_CODE_SESSION_ID", "claude"), ("CODEX_THREAD_ID", "codex")] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return "\(kind):\(value)" }
        }
        return nil
    }

    public static func request(environment: [String: String], name flag: String?, agent: String?,
                               walk: () -> AgentAncestor? = current, workdir: (Int32) -> String? = workdir,
                               cwd: String = FileManager.default.currentDirectoryPath, home: String = NSHomeDirectory()) -> [String: Any] {
        var said: [String: Any] = [:]
        if let id = agent ?? environment["BROADWAY_AGENT"].flatMap({ $0.isEmpty ? nil : $0 }) { said["id"] = id }
        let named = flag ?? environment["BROADWAY_AGENT_NAME"].flatMap { $0.isEmpty ? nil : $0 }
        if let named {
            said["name"] = named
            said["named"] = true
        }
        if said["id"] == nil, let session = session(environment) { said["session"] = session }
        let here = (cwd as NSString).standardizingPath
        let login = environment["SSH_CONNECTION"] != nil && here == (home as NSString).standardizingPath
        var works: String? = here.hasPrefix("/") && !login ? here : nil
        if said["id"] == nil {
            let found = walk()
            if said["session"] == nil, let remote = remote(environment: environment, found: found) {
                said["id"] = named.map { "\(remote.id)/\($0.lowercased())" } ?? remote.id
                said["name"] = named ?? remote.name
            } else if let found {
                said["pid"] = Int(found.pid)
                said["started"] = found.started
                said["executable"] = plain(found.name)
                if let own = workdir(found.pid), own.hasPrefix("/") { works = own }
            }
        }
        if let works { said["workdir"] = works }
        return said.merging(place(environment: environment, cwd: cwd)) { old, _ in old }
    }

    public static func workdir(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    public static func place(environment: [String: String], cwd: String, look: (String) -> GitMark? = GitMark.look) -> [String: Any] {
        var said: [String: Any] = [:]
        if let space = environment["BROADWAY_SPACE"]?.trimmingCharacters(in: .whitespaces), !space.isEmpty { said["space"] = space }
        let here = (cwd as NSString).standardizingPath
        guard here.hasPrefix("/") else { return said }
        said["cwd"] = here
        said["folder"] = project(from: here, look: look)
        return said
    }

    public enum GitMark: Equatable {
        case folder
        case file(String)

        public static func look(_ path: String) -> GitMark? {
            let mark = (path as NSString).appendingPathComponent(".git")
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mark, isDirectory: &folder) else { return nil }
            if folder.boolValue { return .folder }
            let text = (try? String(contentsOfFile: mark, encoding: .utf8)) ?? ""
            return .file(text)
        }
    }

    public static func project(from cwd: String, look: (String) -> GitMark?) -> String {
        var path = cwd
        while path != "/", !path.isEmpty {
            switch look(path) {
            case .folder:
                return path
            case .file(let text):
                return worktreeHome(text) ?? path
            case nil:
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return cwd
    }

    static func worktreeHome(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard gitdir.hasPrefix("/"), let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        let home = String(gitdir[..<range.lowerBound])
        return home.isEmpty ? nil : home
    }
}

extension Context {
    static let agent: [String: Any] = AgentAncestor.request(environment: ProcessInfo.processInfo.environment, name: nil, agent: nil)
}
