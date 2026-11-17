import AppKit
import Foundation

@MainActor
enum BenchSaveAsk {
    static func run(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "saveask only works on a --test run"]) }
        let ask = SaveAsk.shared
        let id = values.dropFirst().first.flatMap(UUID.init(uuidString:))
        switch action {
        case "answer":
            guard let path = values.first, !path.isEmpty else { return answer(["error": "saveask answer needs a path"]) }
            guard ask.answer(URL(fileURLWithPath: path), id: id) else { return answer(["error": "no question is up to answer"]) }
        case "cancel":
            guard ask.cancel(id: values.first.flatMap(UUID.init(uuidString:))) else { return answer(["error": "no question to cancel"]) }
        case "real": ask.realNext = values.first == "off" ? 0 : values.first.flatMap(Int.init) ?? 1
        case "state": break
        default: return answer(["error": "unknown saveask action"])
        }
        var state = ask.state()
        state["folders"] = Store.settings.dictionary(forKey: SaveAsk.foldersKey) ?? [:]
        state["asks"] = browser.prefs.asksWhereToSave
        answer(state)
    }
}
