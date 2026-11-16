import AppKit

extension Bench {
    func snippetCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "snippets only works on a test run"]); return }
        let store = SnippetStore.shared
        let action = request["action"] as? String ?? "list"
        switch action {
        case "inspect":
            answer(["waiting": browser.snippetField.waiting,
                    "selectionFailed": browser.snippetField.selectionFailed,
                    "frame": browser.active?.snippetFrame != nil,
                    "checked": browser.snippetField.checked ?? "pending",
                    "target": browser.snippetField.target != nil])
            return
        case "undo":
            guard let undo = browser.active?.built?.undoManager, undo.canUndo else {
                answer(["error": "the focused page has no native undo action"])
                return
            }
            undo.undo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                answer(["canUndo": undo.canUndo, "canRedo": undo.canRedo])
            }
            return
        case "save":
            var snippet = Snippet()
            if let id = request["id"] as? String {
                guard let found = store.snippets.first(where: { $0.id.uuidString == id }) else {
                    answer(["error": "no snippet with that id"])
                    return
                }
                snippet = found
            }
            snippet.title = request["title"] as? String ?? snippet.title
            snippet.keyword = request["keyword"] as? String ?? snippet.keyword
            snippet.text = request["text"] as? String ?? snippet.text
            if let problem = store.save(snippet) { answer(["error": problem]); return }
        case "delete":
            guard let raw = request["id"] as? String, let id = UUID(uuidString: raw) else {
                answer(["error": "a snippet id is needed"])
                return
            }
            if let problem = store.delete(id) { answer(["error": problem]); return }
        case "list": break
        default: answer(["error": "snippets list|save|delete|undo"]); return
        }
        if browser.fieldShowing { browser.retype() }
        answer(["snippets": store.snippets.map { ["id": $0.id.uuidString, "title": $0.title, "keyword": $0.keyword, "text": $0.text] }])
    }
}
