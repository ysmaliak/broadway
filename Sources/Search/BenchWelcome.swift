import AppKit

@MainActor
enum BenchWelcome {
    static let verbs: Set<String> = ["welcome", "onboarding", "about", "delight", "trouble"]
    private static var held: [(TimeInterval, () -> Void)] = []

    static func run(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let action = request["action"] as? String ?? "state"
        guard Store.testing else {
            answer(["error": "\(verb) only works on a --test run"])
            return
        }
        switch verb {
        case "welcome", "onboarding":
            let onboarding = Onboarding.shared
            if action == "replay" {
                onboarding.abandon()
                onboarding.stage = OnboardingShow.shared
                let waits = request["hold"] as? Bool ?? false
                OnboardingShow.shared.waits = waits
                if waits {
                    onboarding.after = { delay, work in held.append((delay, work)) }
                }
                onboarding.begin(in: browser, reduced: request["reduced"] as? Bool ?? Motion.reduced)
            } else if action == "roll" {
                OnboardingShow.shared.waits = false
                OnboardingShow.shared.roll()
                onboarding.after = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
                for (delay, work) in held { onboarding.after(delay, work) }
                held = []
            } else if action == "skip" {
                onboarding.endIntro()
            } else if action == "primary" {
                onboarding.primary()
            } else if action == "later" {
                onboarding.later()
            } else if action == "close" {
                onboarding.close()
            } else if action.hasPrefix("go:"), let step = Onboarding.Step(rawValue: String(action.dropFirst(3))) {
                onboarding.go(step)
            } else if action.hasPrefix("name:") {
                onboarding.name = String(action.dropFirst(5))
            } else if action.hasPrefix("look:") {
                onboarding.look = String(action.dropFirst(5))
            } else if action.hasPrefix("side:"), let side = SidebarPosition(rawValue: String(action.dropFirst(5))) {
                onboarding.side = side
            } else if action.hasPrefix("source:") {
                onboarding.source = String(action.dropFirst(7))
            } else if action.hasPrefix("key:") {
                onboarding.keyTyped = String(action.dropFirst(4))
            } else if action == "keys-page" {
                onboarding.openKeysPage()
            } else if action == "press" {
                press(request["key"] as? String ?? "", into: onboarding)
            }
            let window = OnboardingShow.shared.window
            answer([
                "phase": String(describing: onboarding.phase),
                "shown": onboarding.showing,
                "ends": onboarding.score.ends,
                "step": onboarding.step.rawValue,
                "index": onboarding.index,
                "steps": onboarding.steps.map(\.rawValue),
                "seen": onboarding.seen,
                "defaultAsked": onboarding.defaultAsked,
                "bringing": browser.bringingIn ?? "",
                "isBringing": browser.bringingIn != nil,
                "typed": browser.typed,
                "name": browser.space.name,
                "look": SpaceLook.offeredID(of: browser.space.look),
                "side": browser.prefs.sidePosition.rawValue,
                "agents": browser.prefs.agentsOn,
                "keySaved": OpenRouterKey.shared.present,
                "keyNote": onboarding.keyNote ?? "",
                "opened": onboarding.opened.map(\.absoluteString),
                "sources": onboarding.sources(),
                "window": window?.windowNumber ?? 0,
                "frame": window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
                "mainShown": browser.window?.isVisible ?? false,
                "active": NSApp.isActive,
                "key": window?.isKeyWindow ?? false,
                "level": window?.level.rawValue ?? 0,
            ])
        case "about":
            AboutWindow.show()
            guard let panel = AboutWindow.panel ?? AboutWindow.made else {
                answer(["error": "no about panel among " + NSApp.windows.map {
                    "\(NSStringFromClass(type(of: $0))) \($0.isVisible) \($0.contentView.map(AboutWindow.texts(in:)) ?? [])"
                }.joined(separator: " | ")])
                return
            }
            if !panel.isVisible {
                panel.hidesOnDeactivate = false
                panel.benchShowBehind()
            }
            if let look = request["look"] as? String {
                panel.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
            }
            panel.contentView?.needsDisplay = true
            panel.displayIfNeeded()
            let said: [String: Any] = [
                "window": panel.windowNumber, "title": panel.title, "visible": panel.isVisible,
                "hidden": NSApp.isHidden, "active": NSApp.isActive, "onScreen": panel.occlusionState.contains(.visible),
                "panels": AboutWindow.panels.count,
                "frame": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
                "screen": panel.screen.map { [$0.visibleFrame.midX, $0.visibleFrame.midY] } ?? [],
                "closable": panel.styleMask.contains(.closable), "titled": panel.styleMask.contains(.titled),
                "texts": panel.contentView.map(AboutWindow.texts(in:)) ?? [],
            ]
            if request["close"] as? Bool == true { panel.close() }
            answer(said)
        case "delight":
            answer([
                "celebrated": Delight.shared.celebrated.map(\.rawValue),
                "bursting": Delight.shared.burst != nil,
            ])
        case "trouble":
            let tab = browser.active
            answer(["error_seen": TroubleKind.lastSeen, "failure": tab?.failure ?? "", "trouble": tab?.trouble.map { $0.rawValue } ?? ""])
        default:
            answer(["error": "unknown verb"])
        }
    }

    private static func press(_ key: String, into onboarding: Onboarding) {
        let named: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "return": (36, "\r", []), "escape": (53, "\u{1b}", []), "space": (49, " ", []),
            "cmd-w": (13, "w", .command), "cmd-t": (17, "t", .command), "cmd-q": (12, "q", .command),
        ]
        let keys: [(UInt16, String, NSEvent.ModifierFlags)] = named[key].map { [$0] } ?? key.map { (Bench.keyCode(for: $0), String($0), []) }
        for (code, chars, flags) in keys {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: OnboardingShow.shared.window?.windowNumber ?? 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
            ) else { continue }
            _ = onboarding.takes(event)
        }
    }
}
