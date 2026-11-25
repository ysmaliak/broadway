import Foundation

extension SavedAlready {
    static func offer(for sent: SentSignIn, marks: [FillMark?], clear: Bool) async -> Browser.Offer? {
        await Vault.off {
            switch verdict(sent, marks: marks, kept: { Vault.kept(matching: sent.host, wide: true) }, read: Vault.secret(of:)) {
            case .marked:
                return nil
            case .kept(let one):
                Vault.touch(touched(one, by: sent, clear: clear))
                return nil
            case .offer(let changed):
                return Browser.Offer(
                    login: login(for: sent, clear: clear),
                    changed: changed
                )
            }
        }
    }
}
