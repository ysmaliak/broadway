import Foundation

extension SavedAlready {
    static func offer(for sent: SentSignIn, marks: [FillMark?], clear: Bool) async -> Browser.Offer? {
        await Vault.off {
            switch verdict(sent, marks: marks, kept: { Vault.kept(matching: sent.host, wide: true) }, read: Vault.secret(of:)) {
            case .marked:
                return nil
            case .kept(let one):
                Vault.touch(Login(host: one.host, user: one.user, password: sent.password, used: one.used, clear: clear))
                return nil
            case .offer(let changed):
                return Browser.Offer(
                    login: Login(host: sent.host, user: sent.user, password: sent.password, used: nil, clear: clear),
                    changed: changed
                )
            }
        }
    }
}
