import AppKit
import Observation

@MainActor
@Observable
final class NewSpaceAsk {
    private(set) var draft: Onboarding?
    private(set) var created = false
    var accounts = SpaceAccounts.shared

    var up: Bool { draft != nil }

    var name: String { draft?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    var look: SpaceLook? {
        guard let draft, draft.look != SpaceLook.offeredID(of: nil) else { return nil }
        return SpaceLook.offered(draft.look)
    }

    static func draft(in browser: Browser) -> Onboarding {
        let made = Onboarding()
        made.open(at: .space, in: browser)
        made.name = ""
        made.look = SpaceLook.offeredID(of: nil)
        return made
    }

    func open(in browser: Browser) {
        accounts = .shared
        created = false
        draft = Self.draft(in: browser)
    }

    func close(created: Bool = false) {
        guard draft != nil else { return }
        self.created = created
        draft = nil
    }
}

extension Browser {
    var draftLook: SpaceLook { spaceAsk.look ?? SpaceLook() }

    @discardableResult
    func createAskedSpace() -> Bool {
        let name = spaceAsk.name
        guard spaceAsk.up, !name.isEmpty else { return false }
        addSpace(named: name, icon: draftIcon, look: spaceAsk.look, sharesSignIns: spaceAsk.accounts.shares)
        return true
    }
}
