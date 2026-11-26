import AppKit
import Foundation
import WebKit

@MainActor
enum BenchFileChoice {
    static func run(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "filebox only works on a --test run"]) }
        switch action {
        case "enable": Store.settings.set(true, forKey: "filebox.probe")
        case "cancel": browser.fileChoice?.cancel()
        case "pick": browser.fileChoice?.pick()
        case "finder": browser.fileChoice?.chooseInFinder()
        case "key":
            if let code = values.first.flatMap(UInt16.init) { browser.fileChoice?.key(code) }
        case "select":
            if let index = values.first.flatMap(Int.init) {
                var modifiers: NSEvent.ModifierFlags = []
                if values.contains("command") { modifiers.insert(.command) }
                if values.contains("shift") { modifiers.insert(.shift) }
                browser.fileChoice?.select(index, modifiers: modifiers)
            }
        case "submit": _ = browser.fileChoice?.submit(values.map { URL(fileURLWithPath: $0) })
        case "drop":
            let accepted = browser.fileChoice?.drop(values.map { NSItemProvider(contentsOf: URL(fileURLWithPath: $0)) }.compactMap { $0 }) ?? false
            return answer(["accepted": accepted])
        case "shot-start":
            return answer(browser.fileChoice?.beginSnapshot() ?? ["error": "no hidden picker to capture"])
        case "shot-end": browser.fileChoice?.endSnapshot()
        case "peek-eval":
            guard let web = browser.peekTab?.built, let js = values.first else { return answer(["error": "peek-eval needs a peek and script"]) }
            web.evaluateJavaScript(js) { value, error in
                if let error { answer(["error": error.localizedDescription]) }
                else { answer(["value": value ?? NSNull()]) }
            }
            return
        case "state": break
        default: return answer(["error": "unknown filebox action"])
        }
        guard let choice = browser.fileChoice else { return answer(["pending": false, "privateDownloads": browser.privateFileDownloads.count]) }
        answer(["privateDownloads": browser.privateFileDownloads.count, "pending": !choice.reply.finished, "tab": choice.tabID.uuidString.lowercased(), "ready": choice.ready, "keepsWhenInactive": choice.keepsVisibleWhenInactive, "accept": choice.rules.accept, "multiple": choice.rules.multiple,
                "directories": choice.rules.directories, "finder": choice.finderRequested, "preview": choice.previewing,
                "selected": choice.selected.sorted(), "cursor": choice.cursor, "host": choice.host,
                "items": choice.items.map { ["name": $0.name, "source": $0.source, "path": $0.path] }, "trouble": choice.trouble])
    }
}
