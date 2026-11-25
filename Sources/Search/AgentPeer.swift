import BroadwayCLI
import Foundation

@MainActor
enum AgentPeer {
    static func trusted(_ said: [String: Any], peer: Int32, lookup: (Int32) -> AgentAncestor.Process? = AgentAncestor.process) -> [String: Any] {
        guard peer > 1, let found = lookup(peer) else { return said }
        var out = said
        if !AgentAncestor.carrier(found.name), said["direct"] as? Bool != false {
            guard let pid = number(said["pid"]).map(Int32.init), pid > 1 else { return said }
            if above(pid, started: number(said["started"]), from: peer, lookup: lookup) { return said }
            out["pid"] = nil
            out["started"] = nil
            out["executable"] = nil
            if let own = AgentAncestor.find(from: found.parent, lookup: lookup) {
                out["pid"] = Int(own.pid)
                out["started"] = own.started
                out["executable"] = own.name
            }
            return out
        }
        out["pid"] = nil
        out["started"] = nil
        out["remote"] = true
        let session = (said["session"] as? String).map { !$0.isEmpty } == true
        guard said["id"] == nil, !session else { return out }
        out["id"] = "ssh:via-\(peer)-\(found.started)"
        if said["name"] == nil {
            let host = AgentLinks.clean(said["host"] as? String)
            if let executable = AgentLinks.clean(said["executable"] as? String) {
                out["name"] = AgentLinks.displayName(executable: executable)
            } else {
                out["name"] = host.map { "SSH from \($0)" } ?? "SSH"
            }
        }
        return out
    }

    static func above(_ pid: Int32, started: Int64?, from peer: Int32, lookup: (Int32) -> AgentAncestor.Process?) -> Bool {
        var at = peer
        var seen: Set<Int32> = []
        while at > 1, seen.insert(at).inserted, let found = lookup(at) {
            if at == pid { return started == nil || found.started == started }
            at = found.parent
        }
        return false
    }

    private static func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
