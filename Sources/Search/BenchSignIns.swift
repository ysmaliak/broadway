import AppKit

@MainActor
enum BenchSignIns {
    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "signins only works on a --test run"]) }
        let keeper = SignInKeeper.shared
        if let settle = request["settle"] as? Double { keeper.resettle(settle) }
        if request["quit"] as? String == "menu" {
            guard let menu = NSApp.mainMenu?.items.first?.submenu,
                  let at = menu.items.firstIndex(where: { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command })
            else { return answer(["error": "no Quit item in the app menu"]) }
            answer(["quitting": menu.items[at].title])
            let press = Timer(timeInterval: 0.3, repeats: false) { _ in
                MainActor.assumeIsolated { menu.performActionForItem(at: at) }
            }
            RunLoop.main.add(press, forMode: .default)
            return
        }
        answer(["settle": keeper.settle, "watching": keeper.watching.map(\.uuidString).sorted()])
    }
}
