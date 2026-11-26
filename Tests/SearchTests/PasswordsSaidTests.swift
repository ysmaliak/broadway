import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct PasswordsSaidTests {
    private let browser = Browser(record: WindowRecord())

    private func said(_ outcome: Result<Chromium.Found, Error>) -> ImportModel.Said {
        ImportModel.passwordsSaid(outcome, from: "Chrome", into: browser)
    }

    @Test func eachWayAnImportOfPasswordsEndsIsSaidInTheSheetsWords() {
        #expect(said(.failure(Chromium.Trouble.noPassphrase)) == ImportModel.Said(ok: false, text: "macOS didn't hand over Chrome's key. Allow it and try again."))
        #expect(said(.failure(Mozilla.Trouble.primaryPassword))
                == ImportModel.Said(ok: false, text: "Chrome has a primary password. Export your passwords from it and bring in the CSV file."))
        #expect(said(.failure(Chromium.Trouble.unreadable)) == ImportModel.Said(ok: false, text: "No passwords readable in Chrome"))
        #expect(said(.success(Chromium.Found(logins: [], never: []))) == ImportModel.Said(ok: true, text: "0 passwords"))
        var locked = Chromium.Found(logins: [], never: [])
        locked.skipped = 2
        locked.undecrypted = 3
        locked.lockedProfiles = 1
        #expect(said(.success(locked)) == ImportModel.Said(ok: false, text: "0 passwords, 2 skipped with no address, and 3 couldn't be decrypted with Chrome's key."
            + " 1 profile with a primary password was left out. Export its passwords from Chrome as a CSV and bring that in."))
    }
}
