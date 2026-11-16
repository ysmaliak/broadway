import Foundation
@testable import Search

func removeTestDefaults(_ defaults: UserDefaults, suite: String) {
    precondition(suite.hasPrefix("site-permissions-test-") || suite.hasPrefix("broadway.commands.test.") || suite.hasPrefix("bld-ai-offer-store-"))
    Store.removeTestSettings(defaults, suite: suite)
}
