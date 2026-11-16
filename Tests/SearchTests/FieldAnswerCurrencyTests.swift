import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FieldAnswerCurrencyTests {
    private let english = Locale(identifier: "en_US")
    private let russian = Locale(identifier: "ru_RU")
    private let rates = ECBRates(date: "2026-11-03", values: ["EUR": 1, "USD": 1.25, "PLN": 4, "GBP": 0.8, "JPY": 160])
    private let xml = Data("<Envelope><Cube><Cube time='2026-11-03'><Cube currency='USD' rate='1.25'/><Cube currency='PLN' rate='4'/></Cube></Cube></Envelope>".utf8)

    init() {
        keepSetting(Shared.prefs, \.engineSuggests, "search.suggest")
    }

    @Test func currencyQuestionsInBothLanguages() {
        let table: [(String, String, String, Double)] = [
            ("100 usd in eur", "USD", "EUR", 100), ("€50 to zł", "EUR", "PLN", 50),
            ("100 долларов в евро", "USD", "EUR", 100), ("1000 руб в usd", "RUB", "USD", 1000),
            ("$25 in gbp", "USD", "GBP", 25), ("1,000 usd to pln", "USD", "PLN", 1000),
            ("100 USD → EUR", "USD", "EUR", 100), ("what is 50 euros to dollars?", "EUR", "USD", 50),
            ("100 jpy in eur", "JPY", "EUR", 100), ("0 usd to eur", "USD", "EUR", 0),
        ]

        for (typed, from, to, amount) in table {
            let question = FieldCurrency.question(typed, locale: english)
            #expect(question?.from == from, "\(typed)")
            #expect(question?.to == to, "\(typed)")
            #expect(question?.amount == amount, "\(typed)")
        }
        #expect(FieldCurrency.question("1,5 долларов в евро", locale: russian)?.amount == 1.5)
    }

    @Test func conversionAndDatedDetail() throws {
        let table = [("100 usd in eur", "80 EUR"), ("€50 to zł", "200 PLN"),
                     ("100 долларов в евро", "80 EUR"), ("1 jpy in usd", "0.0078125 USD"), ("10 eur to eur", "10 EUR")]

        for (text, want) in table {
            let question = try #require(FieldCurrency.question(text, locale: english))
            let answer = try #require(FieldCurrency.answer(question, rates: rates, locale: english))
            #expect(answer.answer == want, "\(text)")
            #expect(answer.copy == want, "\(text)")
            #expect(answer.kind == .currency)
            #expect(answer.detail == "ECB rate of 2026-11-03")
            #expect(answer.full == (text + " = " + want))
        }
    }

    @Test func russianFormattingAndUngroupedCopy() throws {
        let question = try #require(FieldCurrency.question("10000 долларов в евро", locale: russian))

        let answer = try #require(FieldCurrency.answer(question, rates: rates, locale: russian))

        #expect(answer.copy == "8000 EUR")
        #expect(answer.answer != answer.copy)
    }

    @Test func unsupportedOrMissingRatesDoNotInventAnAnswer() throws {
        let roubles = try #require(FieldCurrency.question("1000 руб в usd", locale: russian))
        let dollars = try #require(FieldCurrency.question("100 usd in eur", locale: english))

        #expect(FieldCurrency.answer(roubles, rates: rates) == nil)
        #expect(FieldCurrency.answer(dollars, rates: nil) == nil)
        #expect(FieldCurrency.answer(dollars, rates: ECBRates(date: "2026-02-30", values: rates.values)) == nil)
    }

    @Test func unrelatedAndIncompleteTextStaysASearch() {
        let texts = ["usd", "100 usd", "usd in eur", "100 in eur", "100 apples in eur", "100 usd in europe", "100 us in eur",
                     "100 usd in eur tomorrow", "https://example.com/100-usd-in-eur", "100 usd", "100 usd to", "€ to zł", "2+2 usd to eur",
                     "1/0 usd in eur", "1000 rubles news", "100 usd in eurozone", "0xff usd in eur", "100% usd in eur"]

        for text in texts { #expect(FieldCurrency.question(text, locale: english) == nil, "\(text)") }
    }

    @Test func ecbxmlIsReadStrictly() {
        let parsed = ECBRates.parse(xml)

        #expect(parsed?.date == "2026-11-03")
        #expect(parsed?.values == ["EUR": 1, "USD": 1.25, "PLN": 4])
        for text in ["", "<html>not rates</html>", "<Cube currency='USD' rate='2'/>",
                     "<Cube time='2026-11-03'><Cube currency='USD' rate='nan'/></Cube>",
                     "<Cube time='2026-11-03'><Cube currency='USD' rate='0'/></Cube>",
                     "<Cube time='2026-02-30'><Cube currency='USD' rate='2'/></Cube>",
                     "<Cube time='2026-11-03'><Cube currency='USD' rate='2'/><Cube currency='USD' rate='3'/></Cube>",
                     "<Cube time='2026-11-03'><Cube currency='EUR' rate='2'/></Cube>",
                     "<root><Cube time='2026-11-03'><Cube currency='USD' rate='2'/></Cube><Cube time='2026-11-04'/></root>"] {
            #expect(ECBRates.parse(Data(text.utf8)) == nil, "\(text)")
        }
        #expect(ECBRates.parse(Data(repeating: 32, count: 65_537)) == nil)
    }

    @Test func sixHourThrottlePersistsAcrossInstances() async {
        let file = Store.file("currency-throttle-\(UUID()).json")
        var requests = 0
        let xml = self.xml
        let first = CurrencyRates(file: file) { requests += 1; return xml }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(requests == 0)

        let fetched = await first.refresh(now: now)
        let skipped = await first.refresh(now: now.addingTimeInterval(21_599))
        let second = CurrencyRates(file: file) { requests += 1; return xml }
        let restartSkipped = await second.refresh(now: now.addingTimeInterval(21_599))
        let refreshed = await second.refresh(now: now.addingTimeInterval(21_600))

        #expect(fetched)
        #expect(!skipped)
        #expect(!restartSkipped)
        #expect(refreshed)
        #expect(requests == 2)
        #expect(second.cache.rates?.date == "2026-11-03")
    }

    @Test func offlineKeepsDatedCacheAndThrottlesFailedAttempts() async {
        let file = Store.file("currency-offline-\(UUID()).json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let xml = self.xml
        let initial = CurrencyRates(file: file) { xml }
        _ = await initial.refresh(now: now)
        var failures = 0
        let offline = CurrencyRates(file: file) { failures += 1; throw URLError(.notConnectedToInternet) }

        let result = await offline.refresh(now: now.addingTimeInterval(21_600))
        let restarted = CurrencyRates(file: file) { failures += 1; throw URLError(.notConnectedToInternet) }
        _ = await restarted.refresh(now: now.addingTimeInterval(21_601))

        #expect(!result)
        #expect(failures == 1)
        #expect(restarted.cache.rates?.date == "2026-11-03")
        #expect(restarted.cache.rates?.values["USD"] == 1.25)
    }

    @Test func concurrentQuestionsShareOneFetch() async {
        var requests = 0
        let xml = self.xml
        let source = CurrencyRates(file: Store.file("currency-concurrent-\(UUID()).json")) {
            requests += 1
            try await Task.sleep(for: .milliseconds(40))
            return xml
        }

        async let first = source.refresh()
        async let second = source.refresh()
        let results = await [first, second]

        #expect(requests == 1)
        #expect(results == [true, true])
    }

    @Test func currencyNeverAsksSearchSuggestionsEvenWithoutRates() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.engineSuggests = true
        defer { browser.closeAll() }

        for words in ["100 usd in eur", "€50 to zł", "100 долларов в евро", "1000 руб в usd", "100 usd", "100 usd in", "100 usd in e"] {
            #expect(browser.engineQuestion(for: words) == nil, "\(words)")
        }
        #expect(browser.engineQuestion(for: "currency exchange offices") != nil)
    }
}
