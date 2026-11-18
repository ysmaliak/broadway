import Foundation

enum CLIGuard {
    static var realAllowed: Bool {
        ProcessInfo.processInfo.environment["SEARCH_REAL_MODEL"] == "1"
    }

    static var underTest: Bool {
        Store.testing || Store.unitTests
    }
}
