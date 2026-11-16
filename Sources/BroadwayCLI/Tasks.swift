import Darwin
import Foundation

enum Tasks {
    static let longestMaterial = 1_000_000

    static func material(force: Bool) -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        var wait = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if !force {
            guard poll(&wait, 1, 250) > 0, wait.revents & Int16(POLLIN | POLLHUP) != 0 else { return nil }
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return String(decoding: data.prefix(longestMaterial), as: UTF8.self)
    }

    static func run(_ options: TaskOptions, context: Context) throws -> Exit {
        let prompt = options.words.joined(separator: " ")
        var request = options.request
        request["op"] = "task"
        request["prompt"] = prompt
        if let piped = material(force: options.stdin) { request["material"] = piped }
        let link = try context.connection()
        guard link.send(request) else { throw Failure("not_running", "Broadway went away", retrySafe: false) }
        return try Follow(link: link, options: options, context: context, command: "task").run()
    }

    static func resume(_ id: String, text: String?, options: TaskOptions, context: Context) throws -> Exit {
        var request: [String: Any] = ["op": "session", "action": "resume", "id": id]
        if let text { request["text"] = text }
        let link = try context.connection()
        guard link.send(request) else { throw Failure("not_running", "Broadway went away", retrySafe: false) }
        return try Follow(link: link, options: options, context: context, command: "session resume").run()
    }
}

final class Follow {
    private let link: Link
    private let options: TaskOptions
    private let context: Context
    private let command: String
    private var console: Console { context.console }
    private var session = ""
    private var answer = ""
    private var steps: [[String: Any]] = []
    private var wrote = false
    private var endsLine = true
    private var clock: DispatchSourceTimer?
    private var interrupt: DispatchSourceSignal?
    private let leaving = NSLock()
    private var left = false

    init(link: Link, options: TaskOptions, context: Context, command: String) {
        self.link = link
        self.options = options
        self.context = context
        self.command = command
    }

    private func say(_ piece: String) {
        answer += piece
        wrote = true
        endsLine = piece.hasSuffix("\n")
        if !console.json { console.put(console.outTTY ? Plain.safe(piece) : piece) }
    }

    private func closeLine() {
        if wrote, !endsLine, !console.json {
            console.line()
            endsLine = true
        }
    }

    private var data: [String: Any] { ["session": session, "answer": answer, "steps": steps] }

    func run() throws -> Exit {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [link] in link.send(["op": "stop"]) }
        source.resume()
        interrupt = source
        while let event = link.object() {
            if let exit = try take(event) { return exit }
        }
        closeLine()
        throw Failure("not_running", "Broadway went away before the task finished", retrySafe: false, data: data)
    }

    private func take(_ event: [String: Any]) throws -> Exit? {
        if let failure = Context.failure(event) { throw failure }
        switch event["event"] as? String {
        case "started":
            session = event["session"] as? String ?? session
            let model = event["model"] as? String ?? ""
            console.progress(console.err.dim("session \(session)\(model.isEmpty ? "" : " · \(Plain.cell(model))")"))
            if options.detach {
                link.send(["op": "detach"])
                console.success(command, ["session": session])
                if !console.json { console.line(session) }
                return .done
            }
        case "attached":
            session = event["session"] as? String ?? session
            console.progress(console.err.dim("session \(session)"))
            say(event["text"] as? String ?? "")
        case "text":
            say(event["text"] as? String ?? "")
        case "step":
            let name = event["name"] as? String ?? ""
            let summary = event["summary"] as? String ?? ""
            steps.append(["name": name, "summary": summary])
            console.progress(console.err.dim("· \(Plain.cell(name))\(summary.isEmpty ? "" : ": \(Plain.cell(summary))")"))
        case "stepDone":
            if event["failed"] as? Bool == true { console.progress(console.err.warn("· \(Plain.cell(event["name"] as? String ?? "")) failed")) }
        case "turn":
            closeLine()
            answer = ""
            wrote = false
        case "question":
            return ask(event)
        case "answered":
            clock?.cancel()
            clock = nil
            console.progress(console.err.dim("Answered"))
        case "done":
            let text = event["text"] as? String ?? ""
            if !wrote { say(text) } else { answer = text.isEmpty ? answer : text }
            closeLine()
            console.success(command, data)
            return .done
        case "failed":
            closeLine()
            var failure = Failure(event["code"] as? String ?? "failed", event["message"] as? String ?? "The task failed", retrySafe: false)
            if failure.hint == nil, !session.isEmpty { failure.hint = "Continue it with broadway session resume \(session) \"what next\"" }
            failure.data = data
            throw failure
        case "stopped":
            closeLine()
            throw Failure("stopped", "Stopped", hint: "", retrySafe: false, exit: .stopped, data: data)
        default:
            break
        }
        return nil
    }

    private func resumeLine(_ id: String, answering: Bool) -> String {
        let world = context.globals.world.map { "--world \($0) " } ?? ""
        return "broadway \(world)session resume \(id)\(answering ? " \"your answer\"" : "")"
    }

    private func needsYou(_ question: String, _ id: String, inBroadway: Bool) -> Failure {
        let line = resumeLine(id, answering: !inBroadway)
        var details = data
        details["question"] = question
        details["resume"] = line
        details["answer_in_broadway"] = inBroadway
        return Failure("needs_you", question, hint: inBroadway ? "Answer in Broadway, then: \(line)" : line, exit: .needsYou, data: details)
    }

    private func leave(_ failure: Failure) -> Never {
        leaving.lock()
        guard !left else {
            leaving.unlock()
            pause()
            exit(failure.exit.rawValue)
        }
        left = true
        leaving.unlock()
        link.send(["op": "detach"])
        closeLine()
        console.failure(command, failure)
        exit(failure.exit.rawValue)
    }

    private func ask(_ event: [String: Any]) -> Exit? {
        let question = Plain.cell(event["text"] as? String ?? "")
        let choices = (event["choices"] as? [String] ?? []).map(Plain.cell)
        let inBroadway = event["inBroadway"] as? Bool ?? false
        let id = event["session"] as? String ?? session
        let needs = needsYou(question, id, inBroadway: inBroadway)
        closeLine()
        let interactive = isatty(STDIN_FILENO) == 1 && console.errTTY && !console.json
        if interactive, !inBroadway, options.waitPerson == nil {
            console.note(console.err.bold(question))
            for (index, choice) in choices.enumerated() { console.note("  \(index + 1). \(choice)") }
            console.note(console.err.dim("Type your answer, or press Control-D to leave it for later"))
            guard let line = readLine(), !line.isEmpty else { leave(needs) }
            let number = Int(line).flatMap { $0 >= 1 && $0 <= choices.count ? choices[$0 - 1] : nil }
            link.send(["op": "answer", "text": number ?? line])
            return nil
        }
        let minutes = options.waitPerson ?? (inBroadway && interactive ? 10 : 0)
        guard minutes > 0 else { leave(needs) }
        console.note(console.err.bold(question))
        console.progress(console.err.dim(inBroadway ? "Waiting for your answer in Broadway" : "Waiting for an answer: \(resumeLine(id, answering: true))"))
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + minutes * 60)
        timer.setEventHandler { [weak self] in self?.leave(needs) }
        timer.resume()
        clock = timer
        return nil
    }
}

extension Builtins {
    static let taskCommands: [Builtin] = [
        Builtin(name: "task", usage: "broadway task \"what to do\" [options]", summary: "Run a task, the same as broadway \"what to do\"", group: "Tasks",
                details: """
                Options:
                  --cli claude|codex     which agent runs it
                  -m, --model MODEL      which model
                  --effort LEVEL         low, medium, high, xhigh, max or ultra
                  --wait-person MINUTES  wait this long for an answer instead of exiting 3
                  --no-person            nobody is there: what needs a person fails at once
                  --detach               start it, print the session id and return
                  --stdin                wait for all of a slow pipe (otherwise 250 ms for its first bytes)

                Steps go to stderr, the answer to stdout. Text piped in goes along as material to read, not as instructions.
                A question exits 3 in a script and prints a resume line. At a terminal it asks you there.
                """,
                examples: ["broadway \"find the cheapest flight to Lisbon\"", "cat notes.md | broadway \"summarize this\"", "broadway task hello --cli codex -m gpt-5 --effort high"]) { context, words in
            let options = try TaskOptions.parse(words)
            guard !options.words.isEmpty else { throw Failure.usage("A task needs words", hint: "broadway task \"what to do\"") }
            return try Tasks.run(options, context: context)
        },
        Builtin(name: "session", usage: "broadway session list | resume ID [TEXT] | stop ID | steer ID TEXT | queue ID TEXT", summary: "See and steer tasks", group: "Tasks",
                details: """
                list    tasks running now, then recent ones
                resume  follow a task again, where TEXT answers its question or continues a finished one
                stop    stop a task
                steer   change what a running task is doing now
                queue   add a step for after this one
                """,
                examples: ["broadway session list", "broadway session resume 1a2b3c4d \"the blue one\"", "broadway session stop 1a2b3c4d"]) { context, words in
            try session(words, context: context)
        },
    ]

    private static func session(_ words: [String], context: Context) throws -> Exit {
        let action = words.first ?? "list"
        let options = try TaskOptions.parse(Array(words.dropFirst()))
        let rest = options.words
        let name = "session \(action)"
        let text = rest.dropFirst().isEmpty ? nil : rest.dropFirst().joined(separator: " ")
        switch action {
        case "list":
            let data = try context.ask(["op": "session", "action": "list"])
            Render.show(Command([:]), data, context: context)
            context.console.success(name, data)
            return .done
        case "resume", "stop", "steer", "queue":
            guard let id = rest.first else { throw Failure.usage("\(action) needs a session id", hint: "Run broadway session list") }
            if action == "resume" { return try Tasks.resume(id, text: text, options: options, context: context) }
            if action != "stop", text == nil { throw Failure.usage("\(action) needs words") }
            var request: [String: Any] = ["op": "session", "action": action, "id": id]
            if let text { request["text"] = text }
            do {
                let data = try context.ask(request)
                context.console.success(name, data)
                if !context.console.json { context.console.progress(context.console.err.dim("Done")) }
            } catch var failure as Failure {
                if failure.code == "not_running", failure.message.contains("session") { failure.hint = Failure.hints["not_running_session"] }
                throw failure
            }
            return .done
        default:
            let near = Near.best(action, in: ["list", "resume", "stop", "steer", "queue"]).map { "Did you mean session \($0)?" }
            throw Failure.usage("session has no \(action)", hint: near ?? "broadway session list, resume, stop, steer or queue")
        }
    }
}
