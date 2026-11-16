import Darwin
import Foundation

enum AgentHook {
    static let agents = ["claude", "codex"]

    static func request(agent: String, event: [String: Any], environment: [String: String]) -> [String: Any]? {
        guard agents.contains(agent), let session = (event["session_id"] as? String)?.trimmingCharacters(in: .whitespaces), !session.isEmpty else { return nil }
        let verb: String
        switch event["hook_event_name"] as? String {
        case "Stop":
            if (event["background_tasks"] as? [Any])?.isEmpty == false { return nil }
            if (event["session_crons"] as? [Any])?.isEmpty == false { return nil }
            verb = "idle"
        case "SessionEnd":
            verb = "done"
        default:
            return nil
        }
        var said = environment
        said["CLAUDE_CODE_SESSION_ID"] = agent == "claude" ? session : nil
        said["CODEX_THREAD_ID"] = agent == "codex" ? session : nil
        return ["op": "do", "noun": "agents", "verb": verb, "arguments": [String: Any](), "wait": 0, "hook": true,
                "agent": AgentAncestor.request(environment: said, name: nil, agent: nil)]
    }

    static func event(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func run(_ agent: String, context: Context) -> Exit {
        guard isatty(STDIN_FILENO) == 0 else { return .done }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = event(data), let request = request(agent: agent, event: event, environment: context.environment),
              let link = context.place.connect() else { return .done }
        link.patience(3)
        if link.send(request) { _ = link.object() }
        return .done
    }
}

enum HookSetup {
    static let events = ["Stop", "SessionEnd"]
    static let seconds = 5

    static func marker(_ agent: String) -> String { "broadway agents idle --hook \(agent)" }

    static func command(_ agent: String) -> String {
        "test -x ~/.local/bin/broadway && ~/.local/bin/broadway agents idle --hook \(agent) || true"
    }

    static func group(_ agent: String) -> JSONText.Value {
        .object([("hooks", .array([.object([("type", .string("command")), ("command", .string(command(agent))), ("timeout", .number(seconds))])]))])
    }

    static func fresh(_ agent: String) -> String {
        let hooks = JSONText.Value.object(events.map { ($0, .array([group(agent)])) })
        return JSONText.Value.object([("hooks", hooks)]).rendered(unit: "  ", level: 0) + "\n"
    }

    static let emptied = "{\n}\n"

    enum Outcome: Equatable {
        case changed(String)
        case same
        case foreign(String)
    }

    static func adding(_ agent: String, to text: String) -> Outcome {
        guard let base = removed(agent, from: text) else { return .foreign(why(text)) }
        var bytes = Array(base.utf8)
        for event in events {
            guard let next = JSONText.add(group(agent), event: event, in: bytes) else { return .foreign(why(text)) }
            bytes = next
        }
        let made = String(decoding: bytes, as: UTF8.self)
        return made == text ? .same : .changed(made)
    }

    static func removing(_ agent: String, from text: String) -> Outcome {
        guard let made = removed(agent, from: text) else { return .foreign(why(text)) }
        return made == text ? .same : .changed(made)
    }

    static func removed(_ agent: String, from text: String) -> String? {
        guard JSONText.valid(text) else { return nil }
        var bytes = Array(text.utf8)
        while let next = JSONText.removeOne(containing: Array(marker(agent).utf8), in: bytes, events: events) {
            if next == bytes { break }
            bytes = next
        }
        guard JSONText.shape(bytes) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func installed(_ agent: String, in text: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker(agent)) == true }
            }
        }
    }

    private static func why(_ text: String) -> String {
        JSONText.valid(text) ? "left alone: its hooks aren't in the usual shape" : "left alone: it isn't plain JSON"
    }
}

enum JSONText {
    indirect enum Value {
        case string(String)
        case number(Int)
        case array([Value])
        case object([(String, Value)])

        func rendered(unit: String, level: Int) -> String {
            let inner = String(repeating: unit, count: level + 1)
            let outer = String(repeating: unit, count: level)
            switch self {
            case .string(let text): return JSONText.quoted(text)
            case .number(let number): return String(number)
            case .array(let items):
                guard !items.isEmpty else { return "[]" }
                return "[\n" + items.map { inner + $0.rendered(unit: unit, level: level + 1) }.joined(separator: ",\n") + "\n" + outer + "]"
            case .object(let pairs):
                guard !pairs.isEmpty else { return "{}" }
                return "{\n" + pairs.map { inner + JSONText.quoted($0.0) + ": " + $0.1.rendered(unit: unit, level: level + 1) }.joined(separator: ",\n") + "\n" + outer + "}"
            }
        }
    }

    struct Member {
        var key: String
        var start: Int
        var value: Range<Int>
    }

    static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    static func valid(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any]
    }

    static func shape(_ bytes: [UInt8]) -> Bool {
        guard let top = root(bytes), let found = members(bytes, at: top) else { return false }
        guard let hooks = found.members.first(where: { $0.key == "hooks" }) else { return true }
        return bytes[hooks.value.lowerBound] == UInt8(ascii: "{")
    }

    static func space(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

    static func skip(_ bytes: [UInt8], _ index: Int) -> Int {
        var at = index
        while at < bytes.count, space(bytes[at]) { at += 1 }
        return at
    }

    static func root(_ bytes: [UInt8]) -> Int? {
        var at = skip(bytes, 0)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { at = skip(bytes, 3) }
        return at < bytes.count && bytes[at] == UInt8(ascii: "{") ? at : nil
    }

    static func stringEnd(_ bytes: [UInt8], _ open: Int) -> Int? {
        var at = open + 1
        while at < bytes.count {
            if bytes[at] == UInt8(ascii: "\\") { at += 2; continue }
            if bytes[at] == UInt8(ascii: "\"") { return at + 1 }
            at += 1
        }
        return nil
    }

    static func valueEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "{"): return members(bytes, at: start).map { $0.close + 1 }
        case UInt8(ascii: "["): return elements(bytes, at: start).map { $0.close + 1 }
        case UInt8(ascii: "\""): return stringEnd(bytes, start)
        default:
            var at = start
            while at < bytes.count, !space(bytes[at]), ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[at]) { at += 1 }
            return at > start ? at : nil
        }
    }

    static func members(_ bytes: [UInt8], at open: Int) -> (members: [Member], close: Int)? {
        var found: [Member] = []
        var at = skip(bytes, open + 1)
        if at < bytes.count, bytes[at] == UInt8(ascii: "}") { return (found, at) }
        while at < bytes.count {
            guard bytes[at] == UInt8(ascii: "\""), let keyEnd = stringEnd(bytes, at) else { return nil }
            let key = (try? JSONSerialization.jsonObject(with: Data(bytes[at..<keyEnd]), options: .fragmentsAllowed)) as? String ?? ""
            var next = skip(bytes, keyEnd)
            guard next < bytes.count, bytes[next] == UInt8(ascii: ":") else { return nil }
            next = skip(bytes, next + 1)
            guard let end = valueEnd(bytes, next) else { return nil }
            found.append(Member(key: key, start: at, value: next..<end))
            at = skip(bytes, end)
            guard at < bytes.count else { return nil }
            if bytes[at] == UInt8(ascii: "}") { return (found, at) }
            guard bytes[at] == UInt8(ascii: ",") else { return nil }
            at = skip(bytes, at + 1)
        }
        return nil
    }

    static func elements(_ bytes: [UInt8], at open: Int) -> (elements: [Range<Int>], close: Int)? {
        var found: [Range<Int>] = []
        var at = skip(bytes, open + 1)
        if at < bytes.count, bytes[at] == UInt8(ascii: "]") { return (found, at) }
        while at < bytes.count {
            guard let end = valueEnd(bytes, at) else { return nil }
            found.append(at..<end)
            at = skip(bytes, end)
            guard at < bytes.count else { return nil }
            if bytes[at] == UInt8(ascii: "]") { return (found, at) }
            guard bytes[at] == UInt8(ascii: ",") else { return nil }
            at = skip(bytes, at + 1)
        }
        return nil
    }

    static func unit(_ bytes: [UInt8], top: Int) -> String {
        guard let newline = bytes[top...].firstIndex(of: 0x0A) else { return "  " }
        var at = newline + 1
        while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x09 { at += 1 }
        let run = String(decoding: bytes[(newline + 1)..<at], as: UTF8.self)
        return run.isEmpty ? "  " : run
    }

    static func splice(_ bytes: [UInt8], _ range: Range<Int>, _ text: String) -> [UInt8] {
        var copy = bytes
        copy.replaceSubrange(range, with: Array(text.utf8))
        return copy
    }

    static func put(_ text: String, into bytes: [UInt8], open: Int, close: Int, last: Range<Int>?, unit: String, level: Int) -> [UInt8] {
        let indent = String(repeating: unit, count: level)
        if let last { return splice(bytes, last.upperBound..<last.upperBound, ",\n" + indent + text) }
        let inside = bytes[(open + 1)..<close].contains(0x0A)
        let tail = inside || level > 1 ? "" : "\n"
        return splice(bytes, (open + 1)..<(open + 1), "\n" + indent + text + tail)
    }

    static func add(_ group: Value, event: String, in bytes: [UInt8]) -> [UInt8]? {
        guard let top = root(bytes), let outer = members(bytes, at: top) else { return nil }
        let unit = unit(bytes, top: top)
        guard let hooks = outer.members.first(where: { $0.key == "hooks" }) else {
            let made = Value.object([(event, .array([group]))]).rendered(unit: unit, level: 1)
            return put(quoted("hooks") + ": " + made, into: bytes, open: top, close: outer.close, last: outer.members.last?.value, unit: unit, level: 1)
        }
        let open = hooks.value.lowerBound
        guard bytes[open] == UInt8(ascii: "{"), let inner = members(bytes, at: open) else { return nil }
        guard let list = inner.members.first(where: { $0.key == event }) else {
            let made = Value.array([group]).rendered(unit: unit, level: 2)
            return put(quoted(event) + ": " + made, into: bytes, open: open, close: inner.close, last: inner.members.last?.value, unit: unit, level: 2)
        }
        let start = list.value.lowerBound
        guard bytes[start] == UInt8(ascii: "["), let items = elements(bytes, at: start) else { return nil }
        return put(group.rendered(unit: unit, level: 3), into: bytes, open: start, close: items.close, last: items.elements.last, unit: unit, level: 3)
    }

    static func cut(_ bytes: [UInt8], _ ranges: [Range<Int>], at index: Int, open: Int) -> [UInt8] {
        if index > 0 { return splice(bytes, ranges[index - 1].upperBound..<ranges[index].upperBound, "") }
        if ranges.count > 1 { return splice(bytes, ranges[0].lowerBound..<ranges[1].lowerBound, "") }
        return splice(bytes, (open + 1)..<ranges[0].upperBound, "")
    }

    static func contains(_ bytes: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        var at = bytes.startIndex
        while at + needle.count <= bytes.endIndex {
            if bytes[at..<(at + needle.count)].elementsEqual(needle) { return true }
            at += 1
        }
        return false
    }

    static func hooks(_ bytes: [UInt8]) -> (top: Int, outer: [Member], index: Int, open: Int, inner: [Member])? {
        guard let top = root(bytes), let outer = members(bytes, at: top),
              let index = outer.members.firstIndex(where: { $0.key == "hooks" }) else { return nil }
        let open = outer.members[index].value.lowerBound
        guard bytes[open] == UInt8(ascii: "{"), let inner = members(bytes, at: open) else { return nil }
        return (top, outer.members, index, open, inner.members)
    }

    static func spans(_ members: [Member]) -> [Range<Int>] {
        members.map { $0.start..<$0.value.upperBound }
    }

    static func removeOne(containing needle: [UInt8], in bytes: [UInt8], events: [String]) -> [UInt8]? {
        guard let found = hooks(bytes) else { return nil }
        for member in found.inner where events.contains(member.key) {
            let start = member.value.lowerBound
            guard bytes[start] == UInt8(ascii: "["), let items = elements(bytes, at: start),
                  let hit = items.elements.firstIndex(where: { contains(bytes[$0], needle) }) else { continue }
            let next = cut(bytes, items.elements, at: hit, open: start)
            return items.elements.count == 1 ? drop(member.key, from: next) ?? next : next
        }
        return nil
    }

    static func drop(_ event: String, from bytes: [UInt8]) -> [UInt8]? {
        guard let found = hooks(bytes), let index = found.inner.firstIndex(where: { $0.key == event }),
              bytes[found.inner[index].value].contains(0x0A) else { return nil }
        let next = cut(bytes, spans(found.inner), at: index, open: found.open)
        guard let left = hooks(next), left.inner.isEmpty, next[left.outer[left.index].value].contains(0x0A) else { return next }
        return cut(next, spans(left.outer), at: left.index, open: left.top)
    }
}
