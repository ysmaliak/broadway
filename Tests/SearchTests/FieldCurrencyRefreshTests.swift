import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FieldCurrencyRefreshTests {
    private func changingQuestion(cached: Bool, picked: Bool) async throws {
        let file = Store.file("currency-field-\(UUID()).json")
        if cached {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cache = CurrencyCache(rates: ECBRates(date: "2026-11-02", values: ["EUR": 1, "USD": 2]),
                                      attemptedAt: Date().addingTimeInterval(-21_601))
            try JSONEncoder().encode(cache).write(to: file)
        }
        var requests = 0
        var response: CheckedContinuation<Data, Never>?
        let rates = CurrencyRates(file: file) {
            requests += 1
            return await withCheckedContinuation { response = $0 }
        }
        let saved = CurrencyRates.shared
        CurrencyRates.shared = rates
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer {
            browser.closeAll()
            CurrencyRates.shared = saved
            response?.resume(returning: Data())
            try? FileManager.default.removeItem(at: file)
        }
        browser.edit()
        browser.typed = "100 usd in eur"
        for _ in 0..<100 where response == nil { try await Task.sleep(for: .milliseconds(5)) }
        let pending = try #require(response)
        response = nil
        browser.typed = "200 usd in eur"
        let selected = try #require(browser.offers.firstIndex { $0.kind == .search })
        if picked { browser.picked = selected }
        let row = browser.offers[selected]
        await Task.yield()
        pending.resume(returning: Data("<Cube time='2026-11-03'><Cube currency='USD' rate='1.25'/></Cube>".utf8))
        for _ in 0..<100 {
            if rates.cache.rates?.date == "2026-11-03", picked || browser.leadingAnswer?.copy == "160 EUR" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests == 1)
        #expect(rates.cache.rates?.date == "2026-11-03")
        if picked {
            #expect(browser.picked == selected)
            #expect(browser.pickedOffer?.id == row.id)
            #expect(browser.leadingAnswer == nil)
        } else {
            #expect(browser.leadingAnswer?.copy == "160 EUR")
            #expect(browser.leadingAnswer?.expression == "200 usd in eur")
            #expect(browser.leadingAnswer?.detail == "ECB rate of 2026-11-03")
        }
    }

    @Test func changedQuestionReceivesPendingRatesWithoutAnotherEdit() async throws {
        try await changingQuestion(cached: false, picked: false)
    }

    @Test func changedQuestionReplacesItsCachedRateWhenPendingRefreshFinishes() async throws {
        try await changingQuestion(cached: true, picked: false)
    }

    @Test func pendingRefreshPreservesAnExplicitlySelectedSearch() async throws {
        try await changingQuestion(cached: false, picked: true)
    }
}
