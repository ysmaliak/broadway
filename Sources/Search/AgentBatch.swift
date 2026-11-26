import BroadwayCLI
import Foundation

enum AgentBatch {
    static let most = 25
    static let stops: Set<String> = ["needs_you", "said_no", "never_here", "driving", "person_only", "secret_field", "refused", "unmet", "moved"]
    static let names: [String: String] = ["go": "navigate", "read": "text", "shot": "screenshot", "fill": "fill_form"]
    static let allowed: Set<String> = Set(Batch.allowed.map { names[$0] ?? $0 }).union(["locate"])

    static let spec = ToolSpec(
        name: "batch",
        description: "Run several steps in one call, each one exactly as if it were called alone, with the same checks. It stops at the first failure and says which steps landed. 25 steps at most.",
        properties: [
            "steps": ["type": "array", "description": "Steps in order, each {\"tool\": \"click\", \"arguments\": {\"target\": {\"words\": \"Add to basket\"}}}",
                      "items": ["type": "object"]],
            "keep_going": ["type": "boolean", "description": "Go on after a failure, but never past a needed yes, the person's no or a refusal"],
            "tab": ["type": "string", "description": "A tab id from tabs"],
        ],
        required: ["steps"])

    struct Refusal: Error {
        var code: String
        var message: String
        var step: Int?
    }

    struct Step {
        var n: Int
        var tool: String
        var arguments: [String: Any]
        var line: String
    }

    static func tool(_ name: String, in tools: [ToolSpec]) -> String? {
        if tools.contains(where: { $0.name == name }) { return name }
        if let other = names[name], tools.contains(where: { $0.name == other }) { return other }
        if name == "find", tools.contains(where: { $0.name == "locate" }) { return "locate" }
        if name == "locate", tools.contains(where: { $0.name == "find" }) { return "find" }
        return nil
    }

    static func parse(_ arguments: [String: Any], tools: [ToolSpec]) -> Result<[Step], Refusal> {
        func refuse(_ message: String, _ n: Int? = nil) -> Result<[Step], Refusal> {
            .failure(Refusal(code: "usage", message: n.map { "Step \($0): \(message)" } ?? message, step: n))
        }
        if arguments["lines"] != nil, arguments["steps"] == nil {
            return refuse("Give steps as tool and arguments, since lines need the broadway command to read them")
        }
        guard let given = arguments["steps"] as? [Any], !given.isEmpty else { return refuse("batch needs steps") }
        guard given.count <= most else { return refuse("batch takes \(most) steps at most, not \(given.count)") }
        var found: [Step] = []
        for (index, item) in given.enumerated() {
            guard let object = item as? [String: Any] else { return refuse("a step is an object with tool and arguments", index + 1) }
            let n = object["n"] as? Int ?? index + 1
            let asked = object["tool"] as? String ?? ""
            if PersonGive.mcpNames.contains(asked) {
                return .failure(Refusal(code: "person_only", message: "Step \(n): \(PersonGive.mcpLine)", step: n))
            }
            guard allowed.contains(asked) || names[asked] != nil else {
                return refuse("\(asked.isEmpty ? "a step without a tool" : asked) can't be a batch step", n)
            }
            guard let name = tool(asked, in: tools), allowed.contains(name) else {
                return refuse("Broadway has no \(asked) tool", n)
            }
            if let given = object["arguments"], !(given is [String: Any]) { return refuse("arguments is an object", n) }
            found.append(Step(n: n, tool: name, arguments: object["arguments"] as? [String: Any] ?? [:], line: object["line"] as? String ?? name))
        }
        return .success(found)
    }

    @MainActor
    static func run(_ steps: [Step], of total: Int? = nil, keepGoing: Bool, call: @MainActor (Step) async -> [String: Any]) async -> [String: Any] {
        var reported: [[String: Any]] = []
        var landed: [Int] = []
        var failure: (step: Step, error: [String: Any])?
        var page: Any?
        var tab: Any?
        var stopped = false
        var shift: (n: Int, dialog: Bool)?
        for step in steps {
            if stopped || Task.isCancelled {
                reported.append(["n": step.n, "line": step.line, "ran": false])
                continue
            }
            if let moved = moved(step, after: shift) {
                let error: [String: Any] = ["code": "moved", "message": moved, "retry_safe": true]
                reported.append(["n": step.n, "line": step.line, "ok": false, "ran": false, "error": error])
                if failure == nil { failure = (step, error) }
                stopped = true
                continue
            }
            let reply = await call(step)
            if reply["ok"] as? Bool == true {
                let data = reply["data"] as? [String: Any] ?? [:]
                landed.append(step.n)
                reported.append(["n": step.n, "line": step.line, "ok": true, "data": data])
                if let seen = data["page"] { page = seen }
                if let seen = data["tab"] ?? data["id"] { tab = seen }
                if let now = shifted(data) {
                    shift = (step.n, now)
                } else if shift?.dialog == true {
                    shift = nil
                }
                if let expect = data["expect"] as? [String: Any], expect["met"] as? Bool == false {
                    let want = expect["want"] as? String ?? ""
                    let error: [String: Any] = ["code": "unmet", "message": "Step \(step.n) landed, but \"\(want)\" didn't follow", "retry_safe": false]
                    reported[reported.count - 1]["unmet"] = true
                    if failure == nil { failure = (step, error) }
                    stopped = true
                }
                continue
            }
            let error = reply["error"] as? [String: Any] ?? ["code": "failed", "message": "That didn't work", "retry_safe": false]
            reported.append(["n": step.n, "line": step.line, "ok": false, "error": error])
            if failure == nil { failure = (step, error) }
            if !keepGoing || stops.contains(error["code"] as? String ?? "") { stopped = true }
        }
        var data: [String: Any] = ["ran": reported.filter { $0["ran"] as? Bool != false }.count, "of": total ?? steps.count, "landed": landed, "steps": reported]
        if keepGoing { data["keep_going"] = true }
        if let page { data["page"] = page }
        if let tab { data["tab"] = tab }
        if reported.contains(where: { ($0["data"] as? [String: Any])?["website"] as? Bool == true }) { data["website"] = true }
        guard let failure else { return ["ok": true, "data": data] }
        let code = failure.error["code"] as? String ?? "failed"
        let n = failure.step.n
        let said = failure.error["message"] as? String ?? code
        let message = code == "needs_you" ? "Step \(n) waits for the person's yes" : ["moved", "unmet"].contains(code) ? said : "Step \(n) failed: \(said)"
        let safe = landed.isEmpty && failure.error["retry_safe"] as? Bool != false
        return ToolFailure.error(code, message, tool: "batch", hint: "broadway batch --from \(n)", retrySafe: safe, data: data)
    }
}

extension AgentBatch {
    static func shifted(_ data: [String: Any]) -> Bool? {
        if let dialog = data["dialog"] as? [String: Any], dialog["accepted"] as? Bool != true { return true }
        if (data["page"] as? [String: Any])?["navigated"] as? Bool == true || data["settled"] as? String == "navigated" { return false }
        return nil
    }

    static func ref(in arguments: [String: Any]) -> String? {
        if let ref = arguments["ref"] as? String, !ref.isEmpty { return ref }
        if let ref = (arguments["target"] as? [String: Any])?["ref"] as? String { return ref }
        if let inside = (arguments["target"] as? [String: Any])?["in"] as? String { return inside }
        if let to = arguments["to"] as? String {
            let bare = AgentRef(to.hasPrefix("@") ? String(to.dropFirst()) : to).ref
            if bare.count > 1, bare.hasPrefix("e"), bare.dropFirst().allSatisfy(\.isNumber) { return to }
        }
        return nil
    }

    static func moved(_ step: Step, after shift: (n: Int, dialog: Bool)?) -> String? {
        guard let shift else { return nil }
        if shift.dialog {
            guard step.tool != "dialog" else { return nil }
            return "Step \(step.n) didn't run because step \(shift.n) opened a dialog, so answer it first with a dialog step"
        }
        guard let ref = ref(in: step.arguments) else { return nil }
        let shown = ref.hasPrefix("@") ? ref : "@" + ref
        return "Step \(step.n) didn't run because it names \(shown) from before step \(shift.n) went to a new page"
    }
}

extension AgentSocket {
    func batch(_ arguments: [String: Any], browser: Browser, link: UUID?) async -> [String: Any] {
        switch AgentBatch.parse(arguments, tools: box.tools) {
        case .failure(let refused):
            return ToolFailure.error(refused.code, refused.message, tool: "batch", data: refused.step.map { ["step": $0] })
        case .success(let steps):
            if let named = arguments["tab"] as? String {
                switch await target(named, browser: browser, link: link) {
                case .failure(let refused): return ToolFailure.error(refused.code, refused.message, tool: "batch")
                case .success(let id): remember(id, link: link)
                }
            }
            return await AgentBatch.run(steps, of: arguments["of"] as? Int, keepGoing: arguments["keep_going"] as? Bool == true) { step in
                guard self.box.open else { return ToolFailure.error("agents_off", "Agents are off in Broadway") }
                guard let spec = self.box.tools.first(where: { $0.name == step.tool }) else {
                    return ToolFailure.error("unknown_tool", "Broadway has no tool named \(step.tool)")
                }
                return await self.perform(step.tool, spec: spec, arguments: step.arguments, browser: browser, link: link)
            }
        }
    }
}
