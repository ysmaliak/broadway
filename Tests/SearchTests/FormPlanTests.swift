import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FormClassifierTests {
    private func verdict(_ field: FormField) -> FieldVerdict { FormClassifier.verdict(field) }

    @Test func autocompleteTokensSayWhatABoxIs() {
        #expect(verdict(FormField(autocomplete: "shipping street-address")) == .fill(.street))
        #expect(verdict(FormField(autocomplete: "section-a billing postal-code")) == .fill(.postal))
        #expect(verdict(FormField(autocomplete: "cc-number")) == .fill(.cardNumber))
        #expect(verdict(FormField(autocomplete: "cc-csc")) == .fill(.cardCode))
        #expect(verdict(FormField(autocomplete: "one-time-code")) == .stay(.code))
        #expect(verdict(FormField(autocomplete: "bday")) == .stay(.birth))
    }

    @Test func wordsSayItWhenThereAreNoTokens() {
        #expect(verdict(FormField(name: "firstName")) == .fill(.givenName))
        #expect(verdict(FormField(name: "last_name")) == .fill(.familyName))
        #expect(verdict(FormField(label: "Full name")) == .fill(.fullName))
        #expect(verdict(FormField(label: "Company")) == .fill(.organization))
        #expect(verdict(FormField(label: "Email address")) == .fill(.email))
        #expect(verdict(FormField(name: "address2")) == .fill(.addressLine2))
        #expect(verdict(FormField(label: "Street address")) == .fill(.addressLine1))
        #expect(verdict(FormField(name: "zip")) == .fill(.postal))
        #expect(verdict(FormField(placeholder: "City")) == .fill(.city))
        #expect(verdict(FormField(label: "Prénom")) == .fill(.givenName))
        #expect(verdict(FormField(type: "tel")) == .fill(.phone))
        #expect(verdict(FormField(type: "tel", name: "cardnumber")) == .fill(.cardNumber))
    }

    @Test func stripesBoxesAreRead() {
        #expect(verdict(FormField(type: "tel", autocomplete: "cc-number", name: "cardnumber")) == .fill(.cardNumber))
        #expect(verdict(FormField(type: "tel", autocomplete: "cc-exp", name: "exp-date", placeholder: "MM / YY")) == .fill(.cardExpiry))
        #expect(verdict(FormField(type: "tel", autocomplete: "cc-csc", name: "cvc")) == .fill(.cardCode))
    }

    @Test func whatStaysYoursStaysYours() {
        let staying: [(FormField, FormStay)] = [
            (FormField(type: "password", name: "password"), .secret),
            (FormField(label: "IBAN"), .bank),
            (FormField(label: "Routing number"), .bank),
            (FormField(label: "Social security number"), .identity),
            (FormField(label: "Passport number"), .identity),
            (FormField(label: "Donation amount"), .money),
            (FormField(label: "Annual salary"), .money),
            (FormField(label: "Date of birth"), .birth),
            (FormField(label: "Gender"), .demographic),
            (FormField(type: "checkbox", label: "I agree to the terms"), .consent),
            (FormField(label: "Security PIN"), .secret),
            (FormField(label: "Promo code", maxLength: 20), .other),
            (FormField(label: "Username"), .other),
            (FormField(type: "search", name: "q"), .other),
        ]

        for (field, stay) in staying {
            #expect(verdict(field) == .stay(stay), "\(field.title)")
        }
    }

    @Test func buttonsAndHiddenBoxesAreNotCounted() {
        #expect(verdict(FormField(type: "hidden")) == .ignored)
        #expect(verdict(FormField(type: "submit")) == .ignored)
        #expect(verdict(FormField(type: "file")) == .ignored)
    }

    @Test func aCodeBoxIsAskedForCarefully() {
        #expect(FormClassifier.isCode(FormField(autocomplete: "one-time-code")))
        #expect(FormClassifier.isCode(FormField(label: "Verification code", maxLength: 6)))
        #expect(FormClassifier.isCode(FormField(name: "otp")))
        #expect(FormClassifier.isCode(FormField(maxLength: 1, singles: 6)))
        #expect(FormClassifier.isCode(FormField(label: "Enter your security code", count: 2)))
        #expect(!FormClassifier.isCode(FormField(label: "Security code", maxLength: 3)))
        #expect(!FormClassifier.isCode(FormField(label: "Security code", count: 9)))
        #expect(!FormClassifier.isCode(FormField(label: "Promo code")))
        #expect(!FormClassifier.isCode(FormField(label: "ZIP code")))
        #expect(!FormClassifier.isCode(FormField(label: "Card code")))
        #expect(!FormClassifier.isCode(FormField(label: "Code", maxLength: 200)))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FormPlannerTests {
    private let secure = URL(string: "https://shop.example/checkout")

    private func sources(card: CardRow? = nil) -> FormSources {
        var profile = AutofillProfile()
        profile.name = "Ada Lovelace"
        profile.email = "ada@example.com"
        profile.phone = "+32 470 12 34 56"
        return FormSources(profile: profile,
                           address: AutofillAddress(label: "Home", line1: "1 Main Street", city: "Ghent", region: "CA", postal: "9000", country: "Belgium"),
                           card: card)
    }

    private var visa: CardRow { CardRow(id: "one", label: "", network: .visa, last: "4242", hasCode: true) }

    @Test func itSaysHowManyGoInAndHowManyStay() {
        let fields = [
            FormField(index: 0, autocomplete: "name"), FormField(index: 1, type: "email"),
            FormField(index: 2, autocomplete: "address-line1"), FormField(index: 3, name: "city"),
            FormField(index: 4, type: "password"), FormField(index: 5, label: "Date of birth"),
        ]

        let plan = FormPlanner.plan(fields, page: secure, privateTab: false, sources: sources())

        #expect(plan.rows.map(\.kind) == [.fullName, .email, .addressLine1, .city])
        #expect(plan.summary == "4 of 6 · 2 stay yours")
    }

    @Test func twoLinesOfStreetStayApartInABoxOfOneLine() {
        var given = sources()
        given.address = AutofillAddress(label: "Home", line1: "1 Main Street", line2: "Unit 2")
        let fields = [FormField(index: 0, type: "text", autocomplete: "street-address"),
                      FormField(index: 1, type: "textarea", autocomplete: "street-address")]

        let plan = FormPlanner.plan(fields, page: secure, privateTab: false, sources: given)

        #expect(plan.rows.first?.value == "1 Main Street, Unit 2")
        #expect(plan.rows.last?.value == "1 Main Street\nUnit 2")
    }

    @Test func aBoxAlreadyFilledIsLeftAlone() {
        let fields = [FormField(index: 0, autocomplete: "email", filled: true), FormField(index: 1, autocomplete: "name")]

        let plan = FormPlanner.plan(fields, page: secure, privateTab: false, sources: sources())

        #expect(plan.rows.map(\.field.index) == [1])
        #expect(plan.summary == "1 of 2 · 1 stay yours")
    }

    @Test func onlyTheFormWithTheCaretIsPlanned() {
        var inside = FormField(index: 1, autocomplete: "name", group: 2)
        inside.focused = true
        let fields = [FormField(index: 0, name: "email", group: 1), inside, FormField(index: 2, name: "city", group: 2)]

        let plan = FormPlanner.plan(fields, page: secure, privateTab: false, sources: sources())

        #expect(plan.rows.map(\.field.index) == [1, 2])
        #expect(plan.total == 2)
    }

    @Test func withNoCaretTheFormThatTakesMostIsPlanned() {
        let fields = [FormField(index: 0, type: "email", group: 1), FormField(index: 1, name: "name", group: 2), FormField(index: 2, name: "city", group: 2)]

        let plan = FormPlanner.plan(fields, page: secure, privateTab: false, sources: sources())

        #expect(plan.rows.map(\.field.index) == [1, 2])
    }

    @Test func aPreviewNeverHoldsACardsNumber() throws {
        let fields = [FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "cc-exp"), FormField(index: 2, autocomplete: "cc-csc")]

        let plan = FormPlanner.plan(fields, page: secure, privateTab: false, sources: sources(card: visa))

        #expect(plan.rows.map(\.shown) == ["Visa ···· 4242", "••••", "••••"])
        #expect(plan.rows.allSatisfy { $0.value == nil })
        #expect(plan.needsCard)
    }

    @Test func anInsecurePageGetsNoCardAndSaysWhy() {
        let fields = [FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "name")]

        let plan = FormPlanner.plan(fields, page: URL(string: "http://shop.example/"), privateTab: false, sources: sources(card: visa))

        #expect(plan.rows.map(\.kind) == [.fullName])
        #expect(!plan.needsCard)
        #expect(plan.note == "Cards are never filled on an insecure page")
    }

    @Test func aSavedCardWithoutACodeLeavesTheCodeToYou() {
        var card = visa
        card.hasCode = false

        let plan = FormPlanner.plan([FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "cc-csc")],
                                    page: secure, privateTab: false, sources: sources(card: card))

        #expect(plan.rows.map(\.kind) == [.cardNumber])
        #expect(plan.stays == 1)
    }

    @Test func cardValuesTakeTheShapeOfTheirBox() {
        let card = CardSecret(number: "4242424242424242", expiry: CardExpiry(month: 3, year: 2031)!, holder: "Ada", securityCode: "737")

        #expect(FormPlanner.cardValue(.cardExpiry, field: FormField(), card: card) == "03/31")
        #expect(FormPlanner.cardValue(.cardExpiry, field: FormField(placeholder: "MM / YY"), card: card) == "03 / 31")
        #expect(FormPlanner.cardValue(.cardExpiry, field: FormField(placeholder: "MM/YYYY"), card: card) == "03/2031")
        #expect(FormPlanner.cardValue(.cardExpiry, field: FormField(maxLength: 4), card: card) == "0331")
        #expect(FormPlanner.cardValue(.cardExpiryYear, field: FormField(maxLength: 2), card: card) == "31")
        let months = FormField(type: "select", options: [.init(value: "", text: "Month"), .init(value: "3", text: "March (03)")])
        #expect(FormPlanner.cardValue(.cardExpiryMonth, field: months, card: card) == "3")
        #expect(FormPlanner.cardValue(.cardCode, field: FormField(), card: card) == "737")
    }

    @Test func aPickerIsAnsweredWithOneOfItsOwnOptions() {
        let countries: [FormField.Option] = [.init(value: "", text: "Country"), .init(value: "BE", text: "Belgium"), .init(value: "FR", text: "France")]
        let states: [FormField.Option] = [.init(value: "CA", text: "California"), .init(value: "NY", text: "New York")]

        #expect(FormOptions.pick("Belgium", kind: .country, in: countries) == "BE")
        #expect(FormOptions.pick("be", kind: .country, in: countries) == "BE")
        #expect(FormOptions.pick("CA", kind: .region, in: states) == "CA")
        #expect(FormOptions.pick("new york", kind: .region, in: states) == "NY")
        #expect(FormOptions.pick("Texas", kind: .region, in: states) == nil)
    }

    @Test func aPickerWithoutTheAnswerStaysYours() {
        let field = FormField(index: 0, type: "select", name: "country", options: [.init(value: "FR", text: "France")])

        let plan = FormPlanner.plan([field], page: secure, privateTab: false, sources: sources())

        #expect(plan.rows.isEmpty)
    }

    @Test func framesOnlyTakeWhatTheyAreMeantTo() {
        let stripe = FormField(frame: "f", origin: "https://js.stripe.com", autocomplete: "cc-number")
        let stranger = FormField(frame: "g", origin: "https://ads.example", autocomplete: "cc-number")
        let own = FormField(frame: "h", origin: "https://pay.shop.example", autocomplete: "email")
        let plain = FormField(frame: "i", origin: "http://js.stripe.com", autocomplete: "cc-number")

        #expect(FormFrames.allowed(stripe, kind: .cardNumber, page: secure))
        #expect(!FormFrames.allowed(stripe, kind: .email, page: secure))
        #expect(!FormFrames.allowed(stranger, kind: .cardNumber, page: secure))
        #expect(FormFrames.allowed(own, kind: .email, page: secure))
        #expect(!FormFrames.allowed(plain, kind: .cardNumber, page: secure))
    }

    @Test func aStrangersFrameIsNotEvenCounted() {
        let fields = [FormField(index: 0, autocomplete: "name"), FormField(frame: "g", origin: "https://ads.example", index: 0, autocomplete: "email")]

        let plan = FormPlanner.plan(fields, page: secure, privateTab: false, sources: sources())

        #expect(plan.total == 1)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FormCaptureTests {
    @Test func aSubmittedCardIsReadWithoutItsCode() {
        let fields = [FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "cc-exp"),
                      FormField(index: 2, autocomplete: "cc-csc"), FormField(index: 3, autocomplete: "cc-name")]
        let values = [":0": "4242 4242 4242 4242", ":1": "12 / 29", ":2": "737", ":3": "Ada"]

        let keep = FormCapture.keep(fields, values: values)

        guard case .card(let card)? = keep else { Issue.record("no card"); return }
        #expect(card.number == "4242424242424242")
        #expect(card.expiry == CardExpiry(month: 12, year: 2029))
        #expect(card.holder == "Ada")
        #expect(card.securityCode == "")
    }

    @Test func aMistypedCardIsNotOfferedAKeep() {
        let fields = [FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "cc-exp")]

        let keep = FormCapture.keep(fields, values: [":0": "4242 4242 4242 4241", ":1": "12/29"])

        #expect(keep == nil)
    }

    @Test func aShippingAddressIsReadFromItsBoxes() {
        let fields = [FormField(index: 0, autocomplete: "given-name"), FormField(index: 1, autocomplete: "family-name"),
                      FormField(index: 2, autocomplete: "address-line1"), FormField(index: 3, name: "city"),
                      FormField(index: 4, type: "select", name: "country", options: [.init(value: "BE", text: "Belgium")])]

        let keep = FormCapture.keep(fields, values: [":0": "Ada", ":1": "Lovelace", ":2": "1 Main Street", ":3": "Ghent", ":4": "BE"])

        guard case .address(let address)? = keep else { Issue.record("no address"); return }
        #expect(address.name == "Ada Lovelace")
        #expect(address.line1 == "1 Main Street")
        #expect(address.country == "Belgium")
    }

    @Test func aStreetAloneIsNotAnAddress() {
        let keep = FormCapture.keep([FormField(index: 0, autocomplete: "address-line1")], values: [":0": "1 Main Street"])

        #expect(keep == nil)
    }
}
