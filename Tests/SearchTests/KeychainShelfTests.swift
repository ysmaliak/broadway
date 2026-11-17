import Foundation
import Testing
@testable import Search

@Suite("Kept sign-ins in the real keychain")
struct KeychainShelfTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROADWAY_REAL_KEYCHAIN"] == "1", "BROADWAY_REAL_KEYCHAIN=1 runs it by hand"))
    func anItemIsWrittenReadBackAndDeletedWithoutAPrompt() throws {
        let shelf = KeychainShelf(service: "Broadway Sign-ins throwaway \(UUID().uuidString.prefix(12))")
        let account = UUID().uuidString
        defer {
            shelf.remove(account)
            #expect(shelf.read(account) == nil)
        }
        let data = Data("{\"written\":0,\"crumbs\":[]}".utf8)
        let started = ProcessInfo.processInfo.systemUptime

        #expect(shelf.write(data, as: account))
        #expect(shelf.read(account) == data)
        #expect(shelf.accounts() == [account])
        #expect(shelf.write(Data("{}".utf8), as: account))
        #expect(shelf.read(account) == Data("{}".utf8))
        shelf.remove(account)

        #expect(shelf.read(account) == nil)
        #expect(shelf.accounts().isEmpty)
        #expect(ProcessInfo.processInfo.systemUptime - started < 5)
    }
}
