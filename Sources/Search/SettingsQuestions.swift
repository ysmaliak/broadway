import AppKit

struct SettingsQuestion: Equatable {
    let title: String
    let detail: String
    let confirm: String

    @MainActor
    func ask(over window: NSWindow?, then: @escaping () -> Void) {
        Ask.sure(title, detail: detail, confirm: confirm, returnCancels: true, over: window, then: then)
    }

    @MainActor
    var alert: NSAlert { Ask.question(title, detail: detail, confirm: confirm, returnCancels: true) }
}

extension SettingsQuestion {
    static func keyword(_ word: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove the shortcut “\(word)”?",
                         detail: "Typing “\(word)” before a search no longer sends it to that site. Its search address is lost.",
                         confirm: "Remove")
    }

    static func language(_ name: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove \(name)?",
                         detail: "Sites are no longer asked for \(name). You can add it again.",
                         confirm: "Remove")
    }

    static let siteChoices = SettingsQuestion(
        title: "Forget what every site was allowed?",
        detail: "Camera, microphone, location, notification, local network, video speed and floating video choices are forgotten for every site. Each site asks again when it needs one. This can't be undone.",
        confirm: "Forget")

    static func notifications(_ site: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove the notification choice for \(site)?",
                         detail: "It can no longer send notifications. It asks again the next time it wants to.",
                         confirm: "Remove")
    }

    static func localNetwork(_ site: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove the local network choice for \(site)?",
                         detail: "It asks again the next time it tries to reach your local network",
                         confirm: "Remove")
    }

    static func capture(_ what: String, _ site: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove the \(what) choice for \(site)?",
                         detail: "It asks again the next time it wants your \(what)",
                         confirm: "Remove")
    }

    static func popups(_ site: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove the pop-up choice for \(site)?",
                         detail: "It can no longer open pop-ups without a click. You can allow it again when one is blocked.",
                         confirm: "Remove")
    }

    static func videoSpeed(_ site: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove the video speed for \(site)?",
                         detail: "Videos there play at normal speed again until you change it",
                         confirm: "Remove")
    }

    static func neverSave(_ count: Int) -> SettingsQuestion {
        SettingsQuestion(title: count == 1 ? "Forget the site told to stop offering?" : "Forget the \(count) sites told to stop offering?",
                         detail: "Broadway offers to save passwords there again. The list can't be brought back.",
                         confirm: "Forget")
    }

    static func card(_ name: String) -> SettingsQuestion {
        SettingsQuestion(title: "Forget “\(name)”?",
                         detail: "The card is removed from your keychain and is no longer offered in forms. This can't be undone.",
                         confirm: "Forget")
    }

    static func address(_ name: String) -> SettingsQuestion {
        SettingsQuestion(title: name.isEmpty ? "Forget this address?" : "Forget “\(name)”?",
                         detail: "The address is removed from your keychain and is no longer offered in forms. This can't be undone.",
                         confirm: "Forget")
    }

    static func answers(_ count: Int) -> SettingsQuestion {
        SettingsQuestion(title: count == 1 ? "Forget the answers remembered for forms on 1 site?"
                             : "Forget the answers remembered for forms on \(count) sites?",
                         detail: "What you typed into forms there is removed from this Mac. This can't be undone.",
                         confirm: "Forget All")
    }

    static func snippet(_ name: String, keyword: String) -> SettingsQuestion {
        SettingsQuestion(title: "Delete “\(name)”?",
                         detail: "Its text is removed from this Mac, and ;\(keyword) no longer offers it. This can't be undone.",
                         confirm: "Delete")
    }

    static let applePasswords = SettingsQuestion(
        title: "Disconnect Apple Passwords?",
        detail: "Accounts from the Passwords app stop showing under sign-in boxes. To connect again, your Mac shows a new code.",
        confirm: "Disconnect")

    static let recentLinks = SettingsQuestion(
        title: "Clear recent links?",
        detail: "The list is emptied. Your rules stay, and so do the tabs the links opened.",
        confirm: "Clear")

    static func linkRule(_ match: String) -> SettingsQuestion {
        SettingsQuestion(title: match.isEmpty ? "Delete this rule?" : "Delete the rule for \(match)?",
                         detail: "Links it took open as if it weren't there. This can't be undone.",
                         confirm: "Delete Rule")
    }

    static func `extension`(_ name: String, fromStore: Bool) -> SettingsQuestion {
        SettingsQuestion(title: "Remove “\(name)”?",
                         detail: fromStore ? "Its settings and everything it keeps are removed from this Mac. You can add it again from the Chrome Web Store."
                             : "Its settings and everything it keeps are removed from this Mac. You can load it again from its folder.",
                         confirm: "Remove")
    }

    static func recorder(_ name: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove screen recording for “\(name)”?",
                         detail: "It asks again the next time it wants to record your screen",
                         confirm: "Remove")
    }

    static func quickAction(_ name: String) -> SettingsQuestion {
        SettingsQuestion(title: "Delete “\(name)”?",
                         detail: "Its short name no longer opens it. This can't be undone.",
                         confirm: "Delete")
    }

    static func liveFolder(_ name: String, site: String) -> SettingsQuestion {
        SettingsQuestion(title: "Remove “\(name)”?",
                         detail: "Its tabs close with it, and it stops reading \(site)",
                         confirm: "Remove Folder")
    }

    static let builtInActions = SettingsQuestion(
        title: "Restore doc and meet?",
        detail: "New document and New meeting go back to what they were. Your changes to them are lost.",
        confirm: "Restore")

    static let agentCommand = SettingsQuestion(
        title: "Remove the broadway command?",
        detail: "Your shell, Claude Code and Codex lose broadway, its completions and its skill until you set it up again",
        confirm: "Remove")

    static func agent(_ name: String) -> SettingsQuestion {
        SettingsQuestion(title: "Disconnect \(name)?",
                         detail: "It stops driving its tabs, and has to connect again to use Broadway",
                         confirm: "Disconnect")
    }

    static func agentSite(_ site: String, never: Bool) -> SettingsQuestion {
        SettingsQuestion(title: "Remove the answer for \(site)?",
                         detail: "\(never ? "Never Here" : "Always Here") is forgotten, and agents ask you again on \(site)",
                         confirm: "Remove")
    }

    static let shortcuts = SettingsQuestion(
        title: "Reset every shortcut?",
        detail: "Every key you changed goes back to Broadway's own, and the keys you gave to commands that had none are removed. This can't be undone.",
        confirm: "Reset All")
}
