import Darwin
import Foundation
import JavaScriptCore

enum ScriptRun {
    static let most = 200
    static let outputRange = 256...32_000
    static let longest = 600.0
    static let longestSleep = 20_000.0
    static let ending: Set<String> = Batch.personal.union(["unmet", "moved", "deadline", "too_many", "not_running"])
    static let names = Batch.allowed.sorted()

    struct Outcome {
        var printed = ""
        var steps = 0
        var landed: [Int] = []
        var cut = false
        var error: [String: Any]?

        var data: [String: Any] {
            var data: [String: Any] = ["printed": printed, "steps": steps, "landed": landed]
            if cut { data["cut"] = true }
            if let step = error?["step"] { data["step"] = step }
            return data
        }
    }

    final class State {
        let deadline: Date
        let limit: Int
        let seconds: Double
        var outcome = Outcome()
        var ended: [String: Any]?
        var shift: (n: Int, dialog: Bool)?
        var fresh: Set<String> = []

        init(timeout: Double, limit: Int) {
            seconds = timeout
            deadline = Date().addingTimeInterval(timeout)
            self.limit = limit
        }

        var over: Bool { ended != nil || Date() > deadline }

        func print(_ text: String) {
            guard ended == nil, !outcome.cut else { return }
            let line = text + "\n"
            if outcome.printed.count + line.count > limit {
                outcome.printed += String(line.prefix(max(0, limit - outcome.printed.count)))
                outcome.cut = true
            } else {
                outcome.printed += line
            }
        }

        func end(_ error: [String: Any]) -> [String: Any] {
            if ended == nil { ended = error }
            return ["ok": false, "error": ended ?? error]
        }
    }

    static func words(_ name: String, _ given: [Any]) -> [String] {
        var found: [String] = []
        for (index, value) in given.enumerated() {
            if let fields = value as? [String: Any], name == "fill", index == 0 {
                let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
                found.append(String(decoding: data, as: UTF8.self))
            } else if let options = value as? [String: Any] {
                for key in options.keys.sorted() {
                    let flag = key.hasPrefix("-") ? key : "--" + kebab(key)
                    let values = options[key] as? [Any] ?? [options[key] as Any]
                    for each in values {
                        if let yes = each as? Bool, CFGetTypeID(each as CFTypeRef) == CFBooleanGetTypeID() {
                            if yes { found.append(flag) }
                        } else if !(each is NSNull) {
                            found += [flag, word(each, ref: key == "in" || key == "ref" || key == "to")]
                        }
                    }
                }
            } else if !(value is NSNull) {
                found.append(word(value, ref: true))
            }
        }
        return found
    }

    static func word(_ value: Any, ref: Bool) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue == number.doubleValue.rounded() && abs(number.doubleValue) < 1e15 ? String(Int(number.doubleValue)) : number.stringValue
        }
        if let text = value as? String {
            return ref && isRef(text) ? "@" + text : text
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { return String(decoding: data, as: UTF8.self) }
        return "\(value)"
    }

    static func isRef(_ text: String) -> Bool {
        var rest = Substring(text)
        if rest.first == "f", let dot = rest.firstIndex(of: ".") {
            let frame = rest.dropFirst().prefix { $0 != "." }
            guard !frame.isEmpty, frame.allSatisfy(\.isNumber) else { return false }
            rest = rest[rest.index(after: dot)...]
        }
        return rest.count > 1 && rest.first == "e" && rest.dropFirst().allSatisfy(\.isNumber)
    }

    static func kebab(_ key: String) -> String {
        key.reduce(into: "") { out, character in
            if character.isUppercase { out += "-" + character.lowercased() } else { out.append(character) }
        }
    }

    static func refs(in words: [String]) -> [String] {
        words.filter { $0.hasPrefix("@") && isRef(String($0.dropFirst())) }.map { String($0.dropFirst()) }
    }

    static func collect(_ value: Any, into found: inout Set<String>) {
        if let object = value as? [String: Any] {
            if let ref = object["ref"] as? String { found.insert(ref) }
            for (_, inner) in object { collect(inner, into: &found) }
        } else if let list = value as? [Any] {
            for inner in list { collect(inner, into: &found) }
        }
    }

    static func shifted(_ data: [String: Any]) -> Bool? {
        if let dialog = data["dialog"] as? [String: Any], dialog["accepted"] as? Bool != true { return true }
        if (data["page"] as? [String: Any])?["navigated"] as? Bool == true || data["settled"] as? String == "navigated" { return false }
        return nil
    }

    static func moved(_ name: String, _ words: [String], n: Int, state: State) -> String? {
        guard let shift = state.shift else { return nil }
        if shift.dialog {
            guard name != "dialog" else { return nil }
            return "Step \(n) didn't run because step \(shift.n) opened a dialog, so answer it first with dialog"
        }
        guard let old = refs(in: words).first(where: { !state.fresh.contains($0) }) else { return nil }
        return "Step \(n) didn't run because it names @\(old) from before step \(shift.n) went to a new page"
    }

    static func step(_ name: String, _ given: [Any], state: State, send: (String, [String]) -> [String: Any]) -> [String: Any] {
        if let ended = state.ended { return ["ok": false, "error": ended] }
        let n = state.outcome.steps + 1
        guard n <= most else {
            return state.end(["code": "too_many", "message": "A script runs \(most) steps at most", "retry_safe": state.outcome.landed.isEmpty, "step": n])
        }
        guard Date() <= state.deadline else {
            return state.end(["code": "deadline", "message": "The script ran past its \(Answer.seconds(Int(state.seconds * 1000))) s", "retry_safe": false, "step": n])
        }
        if Give.scriptNames.contains(name) {
            state.outcome.steps = n
            return state.end(["code": "person_only", "message": Give.alone, "hint": Give.aloneHint, "retry_safe": true, "step": n])
        }
        let said = words(name, given)
        state.outcome.steps = n
        if let moved = moved(name, said, n: n, state: state) {
            return state.end(["code": "moved", "message": moved, "retry_safe": true, "step": n])
        }
        let reply = send(name, said)
        guard reply["ok"] as? Bool == true else {
            var error = reply["error"] as? [String: Any] ?? ["code": "failed", "message": reply["error"] as? String ?? "That didn't work", "retry_safe": false]
            error["step"] = n
            if ending.contains(error["code"] as? String ?? "") { return state.end(error) }
            return ["ok": false, "error": error]
        }
        var data = reply["data"] as? [String: Any] ?? [:]
        data["image"] = nil
        state.outcome.landed.append(n)
        if let now = shifted(data) {
            state.shift = (n, now)
            state.fresh = []
        } else if state.shift?.dialog == true {
            state.shift = nil
        }
        if state.shift != nil { collect(data, into: &state.fresh) }
        if let expect = data["expect"] as? [String: Any], expect["met"] as? Bool == false {
            let want = expect["want"] as? String ?? ""
            return state.end(["code": "unmet", "message": "Step \(n) landed, but \"\(Answer.cell(want))\" didn't follow", "retry_safe": false, "step": n])
        }
        return ["ok": true, "data": data]
    }

    static let prelude = """
    (function (names) {
      const call = globalThis.__broadway_call, say = globalThis.__broadway_print
      delete globalThis.__broadway_call
      delete globalThis.__broadway_print
      const show = (value) => typeof value === "string" ? value : JSON.stringify(value, null, 2)
      for (const name of names) {
        globalThis[name] = function (...given) {
          const reply = JSON.parse(call(name, JSON.stringify(given)))
          if (reply.ok) return reply.data
          const error = new Error(reply.error.message)
          error.code = reply.error.code
          error.hint = reply.error.hint
          error.retrySafe = reply.error.retry_safe
          error.step = reply.error.step
          throw error
        }
      }
      globalThis.print = (...given) => { say(given.map(show).join(" ")) }
      globalThis.console = { log: globalThis.print }
    })
    """

    typealias ShouldStop = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldStop?, UnsafeMutableRawPointer?) -> Void

    static let setLimit: SetLimit? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit").map { unsafeBitCast($0, to: SetLimit.self) }

    static let stop: ShouldStop = { context, info in
        guard let info else { return true }
        let over = Unmanaged<State>.fromOpaque(info).takeUnretainedValue().over
        if !over, let context { setLimit?(JSContextGetGroup(context), 0.2, stop, info) }
        return over
    }

    static func watch(_ context: JSContext, state: State) {
        setLimit?(JSContextGetGroup(context.jsGlobalContextRef), 0.2, stop, Unmanaged.passUnretained(state).toOpaque())
    }

    static func run(code: String, outputLimit: Int = 8000, timeout: Double = 60, send: @escaping (_ command: String, _ words: [String]) -> [String: Any]) -> Outcome {
        let state = State(timeout: min(max(timeout, 0.1), longest), limit: min(max(outputLimit, outputRange.lowerBound), outputRange.upperBound))
        guard let context = JSContext() else {
            state.outcome.error = ["code": "failed", "message": "Scripts can't run here", "retry_safe": true]
            return state.outcome
        }
        var thrown: JSValue?
        context.exceptionHandler = { _, exception in thrown = exception }
        let call: @convention(block) (String, String) -> String = { name, json in
            let given = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) as? [Any] ?? []
            let reply = step(name, given, state: state, send: send)
            let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok":false,"error":{"code":"failed","message":"That answer couldn't be read"}}"#.utf8)
            return String(decoding: data, as: UTF8.self)
        }
        let say: @convention(block) (String) -> Void = { text in state.print(text) }
        let sleep: @convention(block) (Double) -> Void = { ms in
            let wanted = min(max(ms.isNaN ? 0 : ms, 0), longestSleep) / 1000
            let left = state.deadline.timeIntervalSinceNow
            if left > 0, state.ended == nil { Thread.sleep(forTimeInterval: min(wanted, left)) }
        }
        context.setObject(call, forKeyedSubscript: "__broadway_call" as NSString)
        context.setObject(say, forKeyedSubscript: "__broadway_print" as NSString)
        context.setObject(sleep, forKeyedSubscript: "sleep" as NSString)
        context.evaluateScript(prelude)?.call(withArguments: [names + Give.scriptNames])
        watch(context, state: state)
        let result = context.evaluateScript(code)
        if let ended = state.ended {
            state.outcome.error = ended
        } else if let thrown {
            state.outcome.error = failure(thrown, state: state)
        } else if let result, let promise = context.objectForKeyedSubscript("Promise"), result.isInstance(of: promise) {
            state.outcome.error = ["code": "usage", "message": "The script ended with a promise still pending, and commands answer at once, so leave out async and await", "retry_safe": state.outcome.landed.isEmpty]
        }
        return state.outcome
    }

    static func failure(_ thrown: JSValue, state: State) -> [String: Any] {
        if let code = thrown.objectForKeyedSubscript("code"), code.isString {
            var error: [String: Any] = ["code": code.toString() ?? "failed", "message": thrown.objectForKeyedSubscript("message")?.toString() ?? "That didn't work"]
            if let hint = thrown.objectForKeyedSubscript("hint"), hint.isString { error["hint"] = hint.toString() }
            error["retry_safe"] = state.outcome.landed.isEmpty
            if let step = thrown.objectForKeyedSubscript("step"), step.isNumber { error["step"] = Int(step.toInt32()) }
            return error
        }
        let said = thrown.objectForKeyedSubscript("message").flatMap { $0.isUndefined ? nil : $0.toString() }
        let message = said ?? thrown.toString() ?? "The script failed"
        let line = thrown.objectForKeyedSubscript("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        var error: [String: Any] = ["code": "usage", "message": "The script stopped" + (line.map { " at line \($0)" } ?? "") + ": " + message,
                                    "retry_safe": state.outcome.landed.isEmpty]
        if message.hasPrefix("Can't find variable") { error["hint"] = "The commands are \((names + ["print", "sleep"]).joined(separator: ", "))" }
        if Date() > state.deadline || message.contains("execution terminated") { error = ["code": "deadline", "message": "The script ran past its \(Answer.seconds(Int(state.seconds * 1000))) s", "retry_safe": false] }
        return error
    }

    static func text(_ outcome: Outcome) -> [String] {
        var lines = outcome.printed.isEmpty ? [] : outcome.printed.components(separatedBy: "\n").dropLast().map { String($0) }
        if outcome.cut { lines.append("… the rest of the output was cut") }
        guard let error = outcome.error else {
            lines.append("(\(outcome.steps) step\(outcome.steps == 1 ? "" : "s"))")
            return lines
        }
        let code = error["code"] as? String ?? "failed"
        let message = error["message"] as? String ?? ""
        let place = (error["step"] as? Int).map { "Error at step \($0)" } ?? "Error"
        lines.append("\(place): \(code), \(message)")
        lines.append(outcome.landed.isEmpty ? "Nothing landed" : "Landed \(Batch.ranges(outcome.landed))")
        return lines
    }
}
