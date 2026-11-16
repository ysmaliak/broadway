import Foundation

extension Bench {
    func quickCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let store = QuickActions.shared
        let history = browser.history
        func state() -> [String: Any] {
            ["shown": store.shown(history: history).map { ["id": $0.id, "name": $0.name, "short": $0.short, "address": $0.address] },
             "hidden": store.saved.hidden, "kept": store.saved.kept, "order": store.saved.order,
             "builtInsChanged": store.builtInsChanged]
        }
        let action = request["action"] as? String ?? "state"
        guard action == "state" || Store.testing else { answer(["error": "quick changes only work on a --test run"]); return }
        let id = request["id"] as? String ?? ""
        let name = request["name"] as? String ?? ""
        let short = request["short"] as? String ?? ""
        let address = request["address"] as? String ?? ""
        var done = true
        var problem: String?
        switch action {
        case "state": break
        case "add":
            problem = store.problem(editing: nil, alias: short, address: address)
            done = store.add(name: name, alias: short, address: address) != nil
        case "edit":
            problem = store.problem(editing: id, alias: short, address: address)
            done = store.edit(id, name: name, alias: short, address: address, history: history)
        case "delete": done = store.delete(id, history: history)
        case "move": done = store.move(id, by: request["by"] as? Int ?? 1, history: history)
        case "keep": store.keep(id)
        case "remove": store.remove(id)
        case "restore": store.restoreBuiltIns()
        default:
            answer(["error": "quick takes state, add, edit, delete, move, keep, remove or restore"])
            return
        }
        var reply = state()
        reply["done"] = done
        if let problem { reply["problem"] = problem }
        answer(reply)
    }
}
