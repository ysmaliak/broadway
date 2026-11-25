import AppKit
import WebKit

extension AgentPage {
    static let readyScript = naming + """

    var body = document.body, text = body ? (body.innerText || '').replace(/\\s+/g, ' ').trim() : '';
    var area = innerWidth * innerHeight, pictures = 0, frames = [];
    function shown(r) { return Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0)) * Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0)); }
    if (body) {
      body.querySelectorAll('canvas,img,svg,video,picture,object').forEach(function (el) { if (seen(el)) pictures += shown(el.getBoundingClientRect()); });
      body.querySelectorAll('iframe,frame').forEach(function (f) {
        if (!seen(f) || shown(f.getBoundingClientRect()) < area / 4) return;
        var host = '';
        try { host = new URL(f.src, location.href).hostname; } catch (e) {}
        frames.push(host);
      });
    }
    var pdf = document.contentType === 'application/pdf' || !!document.querySelector('embed[type="application/pdf"],object[type="application/pdf"]');
    return { text: text.length, nodes: body ? body.getElementsByTagName('*').length : 0, ready: document.readyState, pdf: pdf, picture: pictures >= area / 4, frames: frames };
    """
}

enum AgentReadyWait {
    static let bound: TimeInterval = 3
    @TaskLocal static var patience: TimeInterval = bound

    static func patience(_ arguments: [String: Any]) -> TimeInterval {
        guard let seconds = (arguments["settle"] as? NSNumber)?.doubleValue, !AgentTarget.flag(arguments["settle"]) else { return bound }
        return min(max(bound, seconds), AgentSettleRule.longest)
    }

    static func waits(_ said: [String: Any]) -> Bool {
        guard said["failed"] != nil, said["code"] as? String == "not_actionable" else { return false }
        switch said["reason"] as? String {
        case "hidden", "disabled", "moving":
            return true
        case "covered":
            let by = said["by"] as? [String: Any]
            return by?["cookies"] as? Bool != true && (by?["buttons"] as? [Any] ?? []).isEmpty
        default:
            return false
        }
    }

    static func told(_ said: [String: Any], seconds: TimeInterval) -> [String: Any] {
        guard let what = said["what"] as? String, let failed = said["failed"] as? String, failed.hasPrefix(what) else { return said }
        var rest = String(failed.dropFirst(what.count))
        if rest.hasPrefix(" is moving") { rest = " kept moving" + rest.dropFirst(" is moving".count) }
        else if rest.hasPrefix(" is ") { rest = " stayed " + rest.dropFirst(" is ".count) }
        var out = said
        out["failed"] = "Waited \(AgentChange.seconds(Int((seconds * 1000).rounded()))) s. \(what)\(rest)"
        out["waited"] = seconds
        return out
    }

    @MainActor
    static func until(_ look: () async -> [String: Any]?) async -> [String: Any]? {
        let start = Date()
        var looked = false
        while true {
            guard let said = await look() else { return nil }
            guard waits(said) else { return said }
            if Date().timeIntervalSince(start) >= patience || Task.isCancelled { return looked ? told(said, seconds: patience) : said }
            looked = true
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

struct AgentReadiness: Equatable {
    var text = 0
    var nodes = 0
    var ready = "loading"
    var pdf = false
    var picture = false
    var frames: [String] = []

    init(text: Int = 0, nodes: Int = 0, ready: String = "loading", pdf: Bool = false, picture: Bool = false, frames: [String] = []) {
        self.text = text
        self.nodes = nodes
        self.ready = ready
        self.pdf = pdf
        self.picture = picture
        self.frames = frames
    }

    init(_ said: [String: Any]) {
        text = said["text"] as? Int ?? 0
        nodes = said["nodes"] as? Int ?? 0
        ready = said["ready"] as? String ?? "loading"
        pdf = said["pdf"] as? Bool == true
        picture = said["picture"] as? Bool == true
        frames = said["frames"] as? [String] ?? []
    }

    struct Why: Equatable {
        var kind: String
        var said: String
        var hint: String
    }

    static func why(_ found: AgentReadiness?, loading: Bool, address: URL?) -> Why {
        if loading || found?.ready == "loading" {
            return Why(kind: "loading", said: "That page is still loading, so it has nothing to read yet",
                       hint: "broadway wait \"TEXT\" waits for words you expect on it, then read again")
        }
        if found?.pdf == true || (found == nil && address?.pathExtension.lowercased() == "pdf") {
            return Why(kind: "pdf", said: "That page is a PDF, which has no page text to read",
                       hint: "broadway shot shows it, and broadway download --url ADDRESS saves the file")
        }
        guard let found else {
            return Why(kind: "silent", said: "That page gave no answer", hint: "broadway shot shows what is on screen")
        }
        if let host = found.frames.first {
            return Why(kind: "frame", said: "That page is a frame from \(host.isEmpty ? "another page" : host), with no text of its own",
                       hint: "broadway snapshot --text reads inside the frame")
        }
        if found.text > 0 {
            return Why(kind: "clutter", said: "Broadway found no main text on that page", hint: "broadway snapshot --text gives every line of text with the controls")
        }
        if found.picture {
            return Why(kind: "picture", said: "That page is only a picture or a canvas, with no text", hint: "broadway shot shows it, and broadway click --at X,Y clicks a point of that picture")
        }
        return Why(kind: "empty", said: "That page is empty",
                   hint: "broadway wait \"TEXT\" waits for words you expect, and broadway shot shows what is on screen")
    }
}

extension BrowserToolbox {
    static let readyBound: TimeInterval = 5
    static let readyQuiet: TimeInterval = 2

    func readiness(_ tab: Tab) async -> AgentReadiness? {
        (await timed(tab, AgentPage.readyScript, [:], seconds: 2) as? [String: Any]).map(AgentReadiness.init)
    }

    func awaitText(_ tab: Tab, bound: TimeInterval = BrowserToolbox.readyBound, quiet: TimeInterval = BrowserToolbox.readyQuiet) async -> AgentReadiness? {
        let start = Date()
        var last: AgentReadiness?
        var changed = start
        while true {
            let now = await readiness(tab)
            if let now, now.text > 0 { return now }
            if now?.text != last?.text || now?.nodes != last?.nodes || now?.ready != last?.ready { changed = Date() }
            last = now
            let still = now?.ready == "complete" && !tab.loading && Date().timeIntervalSince(changed) >= quiet
            if still || now?.pdf == true || Date().timeIntervalSince(start) >= bound { return now }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func nothingToRead(_ tab: Tab, found: AgentReadiness?) -> ToolOutcome {
        let why = AgentReadiness.why(found, loading: tab.loading, address: tab.pageAddress)
        return .failure(why.said, code: .noAnswer, hint: why.hint, data: ["kind": why.kind, "website": true])
    }
}
