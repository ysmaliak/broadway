import Darwin
import Foundation

public enum Exit: Int32 {
    case done = 0
    case failed = 1
    case mistake = 2
    case needsYou = 3
    case unanswered = 4
    case stopped = 130
}

struct Failure: Error {
    var code: String
    var message: String
    var hint: String?
    var retrySafe: Bool
    var exit: Exit
    var data: [String: Any]?

    init(_ code: String, _ message: String, hint: String? = nil, retrySafe: Bool = true, exit: Exit = .failed, data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.hint = hint ?? Failure.hints[code]
        self.retrySafe = retrySafe
        self.exit = exit
        self.data = data
    }

    static func usage(_ message: String, hint: String? = nil) -> Failure {
        Failure("usage", message, hint: hint, exit: .mistake)
    }

    static let hints: [String: String] = [
        "agents_off": "Turn on Settings › Agents › Let agents use Broadway",
        "not_running": "Open Broadway, then run this again",
        "stale_ref": "Run broadway snapshot and use the new ref",
        "no_tab": "Run broadway tabs for the list, or broadway open URL for a tab of your own",
        "ambiguous_tab": "Run broadway tabs and give more of the id",
        "not_a_page": "Pick a tab showing a web page: broadway tabs",
        "timeout": "Nothing was repeated. Check the page with broadway snapshot, or wait longer with --seconds.",
        "not_actionable": "Run broadway snapshot to see the element's state, then scroll or wait",
        "opens_window": "Use broadway choose REF VALUE for a list, or broadway type for a date, time or colour",
        "unseen": "Ask the person to select the agent's tab in Broadway, then try again",
        "no_answer": "The page may be busy. Check it with broadway snapshot before you try again.",
        "no_window": "Open a window in Broadway",
        "tasks_running": "Stop them with broadway session stop ID, or run broadway quit --force",
        "no_plan": "Sign in to Claude Code or Codex, then run broadway status",
        "no_session": "Run broadway session list",
        "ambiguous_session": "Run broadway session list and give more of the id",
        "not_running_session": "It has finished. Continue it with broadway session resume ID \"what next\".",
        "needs_person": "Run it where someone can answer, or without --no-person",
        "needs_task": "Start a task with broadway \"what to do\" so the person can answer in Broadway",
        "person_only": "Only the person can change this, in Broadway",
    ]
}

struct Style {
    var color: Bool

    static func wanted(tty: Bool, environment: [String: String], flag: Bool) -> Bool {
        tty && !flag && environment["NO_COLOR"].map(\.isEmpty) != false && environment["TERM"] != "dumb"
    }

    private func paint(_ code: String, _ text: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    func dim(_ text: String) -> String { paint("2", text) }
    func bold(_ text: String) -> String { paint("1", text) }
    func bad(_ text: String) -> String { paint("31", text) }
    func good(_ text: String) -> String { paint("32", text) }
    func warn(_ text: String) -> String { paint("33", text) }
}

enum Plain {
    static func cell(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : $0 }))
    }

    static func safe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\n" || $0 == "\t" }))
    }

    static func fit(_ text: String, _ width: Int) -> String {
        guard text.count > width, width > 1 else { return text }
        return String(text.prefix(width - 1)) + "…"
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum Envelope {
    static func object(command: String, data: [String: Any]?, failure: Failure?) -> [String: Any] {
        var error: Any = NSNull()
        if let failure {
            error = ["code": failure.code, "message": failure.message, "hint": failure.hint ?? "", "retry_safe": failure.retrySafe] as [String: Any]
        }
        return ["ok": failure == nil, "command": command, "data": (failure?.data ?? data) ?? NSNull(), "error": error]
    }

    static func line(command: String, data: [String: Any]?, failure: Failure?) -> String {
        let object = object(command: command, data: data, failure: failure)
        let bytes = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
}

final class Console {
    let json: Bool
    let quiet: Bool
    let outTTY: Bool
    let errTTY: Bool
    let out: Style
    let err: Style

    init(json: Bool, quiet: Bool, noColor: Bool, environment: [String: String]) {
        self.json = json
        self.quiet = quiet
        outTTY = isatty(STDOUT_FILENO) == 1
        errTTY = isatty(STDERR_FILENO) == 1
        out = Style(color: Style.wanted(tty: outTTY, environment: environment, flag: noColor))
        err = Style(color: Style.wanted(tty: errTTY, environment: environment, flag: noColor))
    }

    var width: Int {
        var size = winsize()
        guard outTTY, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 100 }
        return Int(size.ws_col)
    }

    private func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }

    func raw(_ data: Data) { write(data, to: STDOUT_FILENO) }
    func put(_ text: String) { write(Data(text.utf8), to: STDOUT_FILENO) }
    func line(_ text: String = "") { put(text + "\n") }
    func note(_ text: String) { write(Data((text + "\n").utf8), to: STDERR_FILENO) }

    func progress(_ text: String) {
        if !quiet { note(text) }
    }

    func success(_ command: String, _ data: [String: Any]?) {
        if json { line(Envelope.line(command: command, data: data, failure: nil)) }
    }

    func failure(_ command: String, _ failure: Failure) {
        if json { return line(Envelope.line(command: command, data: nil, failure: failure)) }
        note(err.bad("broadway: ") + failure.message)
        if let hint = failure.hint, !hint.isEmpty { note(err.dim("hint: ") + hint) }
    }
}
