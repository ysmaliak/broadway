import Foundation
import LocalAuthentication
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CardsTests {
    private let number = "4242 4242 4242 4242"

    private func secret() -> CardSecret {
        CardSecret(number: number, expiry: CardExpiry(month: 12, year: 2029)!, holder: "Ada Lovelace", securityCode: "737")
    }

    @Test func realNumbersPassAndMistypedOnesDoNot() {
        #expect(CardNumber.valid(number))
        #expect(CardNumber.valid("378282246310005"))
        #expect(CardNumber.valid("5555-5555-5555-4444"))
        #expect(!CardNumber.valid("4242 4242 4242 4241"))
        #expect(!CardNumber.valid("4242"))
        #expect(!CardNumber.valid("4242x4242x4242x4242"))
    }

    @Test func theNetworkIsReadFromTheNumber() {
        #expect(CardNetwork.of(number) == .visa)
        #expect(CardNetwork.of("378282246310005") == .amex)
        #expect(CardNetwork.of("5555555555554444") == .mastercard)
        #expect(CardNetwork.of("2223003122003222") == .mastercard)
        #expect(CardNetwork.of("6011111111111117") == .discover)
        #expect(CardNetwork.of("3530111333300000") == .jcb)
        #expect(CardNetwork.of("9999999999999995") == .other)
    }

    @Test func expiryIsReadTheWaysPeopleWriteIt() {
        #expect(CardExpiry("12/29") == CardExpiry(month: 12, year: 2029))
        #expect(CardExpiry("03 / 2031") == CardExpiry(month: 3, year: 2031))
        #expect(CardExpiry("03/31")?.twoDigitMonth == "03")
        #expect(CardExpiry("13/29") == nil)
        #expect(CardExpiry("1229") == nil)
    }

    @Test func printingACardNeverShowsItsNumberOrCode() {
        let card = secret()

        let printed = ["\(card)", String(describing: card), String(reflecting: card), "\(Mirror(reflecting: card).children.map { $0 })"]

        for line in printed {
            #expect(!line.contains("4242 4242"), "\(line)")
            #expect(!line.contains("4242424242424242"), "\(line)")
            #expect(!line.contains("737"), "\(line)")
        }
    }

    @Test func theListHoldsTheNetworkAndLastFourOnly() throws {
        let keeper = MemoryKeeper()
        let book = AutofillBook(keeper: keeper)

        #expect(book.save(card: secret(), label: "Everyday"))
        let reads = keeper.reads
        book.reload()

        let row = try #require(book.cards.first)
        #expect(row.title == "Visa ···· 4242")
        #expect(row.label == "Everyday")
        #expect(keeper.reads == reads)
        let note = try #require(keeper.list(.card).first?.note)
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(note.utf8)) as? [String: Any])
        let shown = fields.filter { $0.key != "id" }.map { "\($0.value)" }.joined(separator: " ")
        #expect(!shown.contains("42424242"))
        #expect(!shown.contains("737"))
        #expect(!shown.contains("2029"))
    }

    @Test func aMistypedCardIsNotKept() {
        let book = AutofillBook(keeper: MemoryKeeper())
        var card = secret()
        card.number = "1234"

        let kept = book.save(card: card)

        #expect(!kept)
        #expect(book.cards.isEmpty)
    }

    @Test func noProofNoRead() throws {
        let keeper = MemoryKeeper()
        let book = AutofillBook(keeper: keeper)
        book.save(card: secret())
        let row = try #require(book.cards.first)
        book.prove = { _, done in done(false) }
        let reads = keeper.reads
        var released: CardSecret? = secret()

        book.release(card: row) { released = $0 }

        #expect(released == nil)
        #expect(keeper.reads == reads)
    }

    @Test func everyReleaseIsProvedAgain() async throws {
        let book = AutofillBook(keeper: MemoryKeeper())
        book.save(card: secret())
        let row = try #require(book.cards.first)
        var asked = 0
        var reason = ""
        book.prove = { said, done in
            asked += 1
            reason = said
            done(true)
        }
        var released: CardSecret?
        let twice = Expectation(description: "released twice")
        twice.expectedFulfillmentCount = 2

        book.release(card: row) {
            released = $0
            twice.fulfill()
        }
        book.release(card: row) {
            released = $0
            twice.fulfill()
        }
        await fulfillment(of: [twice], timeout: 2)

        #expect(asked == 2)
        #expect(released?.number == "4242424242424242")
        #expect(reason.contains("424242") == false)
    }

    @Test func proofFailsClosedWithoutATestAnswer() {
        Ask.testing = nil
        var answer: Bool?

        Owner.prove("anything") { answer = $0 }

        #expect(answer == false)
    }

    @Test func onlyAMacWithNoPasswordSetHasNothingToProveForPasswordsAndCardsAlike() {
        let none = NSError(domain: LAErrorDomain, code: LAError.Code.passcodeNotSet.rawValue)
        let locked = NSError(domain: LAErrorDomain, code: LAError.Code.biometryLockout.rawValue)
        let stranger = NSError(domain: "elsewhere.example", code: 1)

        #expect(Owner.nothingToProve(Owner.code(of: none)))
        #expect(!Owner.nothingToProve(Owner.code(of: locked)))
        #expect(!Owner.nothingToProve(Owner.code(of: stranger)))
        #expect(!Owner.nothingToProve(Owner.code(of: nil)))
    }

    @Test func aCardNotFilledSaysWhyInPlainWords() {
        #expect(Owner.cardRefused(nil) == "Not filled: your card needs Touch ID")
        #expect(Owner.cardRefused(.notInteractive) == "Not filled: the Mac couldn't ask for Touch ID just now")
        #expect(Owner.cardRefused(.biometryNotAvailable) == "Not filled: this Mac can't ask for Touch ID or its password")
    }

    @Test func showingAPasswordFailsClosedWithoutATestAnswerAsACardDoes() {
        Ask.testing = nil
        var answer: Bool?

        Vault.prove("anything") { answer = $0 }

        #expect(answer == false)
    }

    @Test func cardsGoOnlyToSecurePagesAndPrivateTabsAsk() {
        let secure = URL(string: "https://shop.example/pay")
        let plain = URL(string: "http://shop.example/pay")
        let local = URL(string: "http://localhost:8080/pay")

        #expect(CardRules.fill(on: secure, privateTab: false) == .allowed)
        #expect(CardRules.fill(on: secure, privateTab: true) == .askFirst)
        #expect(CardRules.fill(on: plain, privateTab: false) == .refused)
        #expect(CardRules.fill(on: plain, privateTab: true) == .refused)
        #expect(CardRules.fill(on: local, privateTab: false) == .refused)
        #expect(CardRules.fill(on: nil, privateTab: false) == .refused)
    }

    @Test func aSaveIsOfferedOnlyOnASecurePageOfAnOrdinaryTab() {
        let secure = URL(string: "https://shop.example/pay")
        let plain = URL(string: "http://shop.example/pay")

        #expect(CardRules.mayOfferToSave(on: secure, privateTab: false))
        #expect(!CardRules.mayOfferToSave(on: secure, privateTab: true))
        #expect(!CardRules.mayOfferToSave(on: plain, privateTab: false))
    }
}
