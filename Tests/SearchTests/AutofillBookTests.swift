import Foundation
import Security
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AutofillBookTests {
    private func address() -> AutofillAddress {
        AutofillAddress(label: "Home", name: "Ada Lovelace", line1: "12 Sentinelstraat", city: "Ghent", postal: "9000", country: "Belgium")
    }

    @Test func aProfileComesBackAsItWasKept() {
        let book = AutofillBook(keeper: MemoryKeeper())
        var profile = AutofillProfile()
        profile.name = "Ada King Lovelace"
        profile.email = "ada@example.com"
        profile.links = ["https://example.com/ada"]

        #expect(book.save(profile: profile))

        #expect(book.hasProfile)
        #expect(book.profile == profile)
        #expect(book.profile.givenName == "Ada")
        #expect(book.profile.familyName == "King Lovelace")
    }

    @Test func anEmptiedProfileIsForgotten() {
        let book = AutofillBook(keeper: MemoryKeeper())
        var profile = AutofillProfile()
        profile.name = "Ada"
        book.save(profile: profile)

        book.save(profile: AutofillProfile())

        #expect(!book.hasProfile)
    }

    @Test func anAddressIsListedByLabelWithoutReadingIt() {
        let keeper = MemoryKeeper()
        let book = AutofillBook(keeper: keeper)
        let home = address()

        book.save(address: home)
        let reads = keeper.reads
        book.reload()

        #expect(book.addresses == [KeptItem(id: home.id, note: "Home")])
        #expect(keeper.reads == reads)
        #expect(book.address(home.id) == home)
    }

    @Test func anEmptyAddressIsNotKept() {
        let book = AutofillBook(keeper: MemoryKeeper())

        let kept = book.save(address: AutofillAddress(label: "Nothing"))

        #expect(!kept)
        #expect(book.addresses.isEmpty)
    }

    @Test func forgettingAnAddressTakesItOut() {
        let book = AutofillBook(keeper: MemoryKeeper())
        let home = address()
        book.save(address: home)

        book.forget(address: home.id)

        #expect(book.addresses.isEmpty)
        #expect(book.address(home.id) == nil)
    }

    @Test func nothingReachesTheSettingsFile() {
        let book = AutofillBook(keeper: MemoryKeeper())

        book.save(address: address())

        let plain = "\(Store.settings.dictionaryRepresentation())"
        #expect(!plain.contains("Sentinelstraat"))
    }

    @Test func theTestRunNeverOpensTheRealKeychain() {
        #expect(AutofillBook.shared.keeper is MemoryKeeper)
    }

    @Test func theKeychainKeeperWorksInAKeychainOfItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-keeper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var keychain: SecKeychain?
        let path = folder.appendingPathComponent("test.keychain").path
        let made = SecKeychainCreate(path, 4, "test", false, nil, &keychain)
        if !(made == errSecSuccess && keychain != nil) { try Test.cancel("no throwaway keychain here (\(made))") }
        defer { keychain.map { _ = SecKeychainDelete($0) } }
        let keeper = KeychainKeeper(keychain: keychain)

        #expect(keeper.write(.card, id: "one", note: "Visa 4242", data: Data("first".utf8)))
        #expect(keeper.write(.card, id: "one", note: "Visa 4242 new", data: Data("second".utf8)))

        #expect(keeper.list(.card) == [KeptItem(id: "one", note: "Visa 4242 new")])
        #expect(keeper.read(.card, id: "one") == Data("second".utf8))
        #expect(keeper.list(.address).isEmpty)
        #expect(keeper.remove(.card, id: "one"))
        #expect(keeper.list(.card).isEmpty)
    }
}
