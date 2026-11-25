import AppKit

extension SettingsPageView {
    func onePasswordRow() {
        let prefs = prefs
        let setup = OnePasswordSetup.shared
        let id = "passwords.onepassword"
        if prefs.onePassword, setup.state == nil { setup.check() }
        row(id, control: toggle(id, get: { prefs.onePassword }, set: { on in
            prefs.onePassword = on
            if on { setup.check() } else { setup.off() }
        }), detail: { prefs.onePassword ? OnePasswordSetup.words(setup.state) : (SettingsIndex.item(id)?.detail ?? "") })
        shape { [prefs.onePassword ? "on" : "off", OnePasswordSetup.needsAnotherLook(setup.state) ? "again" : ""] }
        if prefs.onePassword, OnePasswordSetup.needsAnotherLook(setup.state) {
            _ = line("1Password isn't ready", "Broadway's own sign-ins still work", id: "passwords.onepassword.again",
                     control: button("Check Again") { setup.check() })
        }
    }
}

extension OnePasswordSetup {
    static func needsAnotherLook(_ state: OnePasswordState?) -> Bool {
        switch state {
        case .missing, .noAccounts, .quiet, .trouble: return true
        case nil, .checking, .ready: return false
        }
    }
}
