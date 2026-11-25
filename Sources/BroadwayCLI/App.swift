import Darwin
import Foundation

extension Builtins {
    static let appCommands: [Builtin] = [
        Builtin(name: "status", usage: "broadway status", summary: "Whether Broadway is running, and what it is doing", group: "Broadway",
                examples: ["broadway status", "broadway status --json"]) { context, _ in
            guard let link = context.place.connect() else {
                throw context.place.whyNot() ?? Failure("not_running", "Broadway isn't running", hint: "Any browser command starts it hidden")
            }
            guard link.send(["op": "status"]), let found = link.object() else { throw Failure("not_running", "Broadway went away") }
            if let failure = Context.failure(found) { throw failure }
            var rows = ["Broadway \(found["version"] as? String ?? "") is running\(found["hidden"] as? Bool == true ? " hidden" : "")"]
            rows.append("Agents: \(found["agents"] as? Bool == true ? "on" : "off")")
            if !context.console.json { rows.forEach(context.console.line) }
            context.console.success("status", found)
            return .done
        },
        Builtin(name: "quit", usage: "broadway quit", summary: "Quit Broadway", group: "Broadway",
                examples: ["broadway quit"]) { context, words in
            let unknown = words.filter { $0 != "--force" }
            if let first = unknown.first { throw Failure.usage("quit doesn't take \(first)") }
            guard context.place.connect() != nil else {
                context.console.success("quit", ["quit": false, "running": false])
                return .done
            }
            let data = try context.ask(["op": "quit", "force": words.contains("--force")])
            context.console.success("quit", data)
            return .done
        },
        Builtin(name: "serve", usage: "broadway serve [--no-person] | broadway serve --stop", summary: "Keep a hidden Broadway open for agents", group: "Broadway",
                details: """
                Stays in the foreground, so it suits a LaunchAgent. While it runs, Broadway doesn't quit after half an hour idle.
                --no-person  nobody is there: what needs a person fails at once
                --stop       quit a served Broadway
                """,
                examples: ["broadway serve", "broadway serve --no-person", "broadway serve --stop"]) { context, words in
            if let first = words.first(where: { $0 != "--stop" && $0 != "--no-person" }) { throw Failure.usage("serve doesn't take \(first)") }
            if words.contains("--stop") {
                guard context.place.connect() != nil else { return .done }
                let data = try context.ask(["op": "quit", "force": true])
                context.console.success("serve", data)
                return .done
            }
            context.place.starting = true
            let link = try context.connection()
            guard link.send(["op": "serve", "person": words.contains("--no-person") ? "none" : "any"]), let reply = link.object() else {
                throw Failure("not_running", "Broadway went away")
            }
            if let failure = Context.failure(reply) { throw failure }
            context.console.progress(context.console.err.dim("Serving. Stop with Control-C or broadway serve --stop."))
            while link.line() != nil {}
            return .done
        },
        Builtin(name: "mcp", usage: "broadway mcp", summary: "The browser as an MCP server on stdio", group: "Broadway",
                details: "For MCP clients that can't run a command line",
                examples: ["broadway mcp"]) { context, words in
            try MCPRelay.run(words, context: context)
        },
    ]
}
