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
            if !passedOver.contains(base.lowercased()), !(base.lowercased() == "node" && lookup(found.parent).map(\.name).map(isAgent) == true) {
                return AgentAncestor(pid: pid, started: found.started, name: base)
            }
            pid = found.parent
        }
        return nil
    }

    static func isAgent(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent.lowercased()
        return ["claude", "codex", "cursor", "windsurf"].contains { base.hasPrefix($0) }
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
        let first = arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let name = !first.isEmpty ? first : path.map { ($0 as NSString).lastPathComponent } ?? command
        guard interpreters.contains(name.lowercased()) else { return name }
        let script = arguments.dropFirst().first { !$0.hasPrefix("-") }?.lowercased() ?? ""
        let base = (script as NSString).lastPathComponent
        if script.contains("claude-code") || base == "claude" || base == "claude.js" { return "claude" }
        if script.contains("@openai/codex") || base == "codex" || base == "codex.js" { return "codex" }
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

    public static func request(environment: [String: String], name flag: String?, agent: String?) -> [String: Any] {
        var said: [String: Any] = [:]
        if let id = agent ?? environment["BROADWAY_AGENT"].flatMap({ $0.isEmpty ? nil : $0 }) { said["id"] = id }
        if let name = flag ?? environment["BROADWAY_AGENT_NAME"].flatMap({ $0.isEmpty ? nil : $0 }) { said["name"] = name }
        if said["id"] == nil, let session = session(environment) { said["session"] = session }
        if said["id"] == nil, let found = current() {
            said["pid"] = Int(found.pid)
            said["started"] = found.started
            said["executable"] = found.name
        }
        return said
    }
}

extension Context {
    static let agent: [String: Any] = AgentAncestor.request(environment: ProcessInfo.processInfo.environment, name: nil, agent: nil)
}
