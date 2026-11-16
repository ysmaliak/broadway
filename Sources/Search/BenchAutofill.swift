import Foundation

extension Bench {
    func autofill(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let forms = browser.forms
        let book = forms.book
        func state() -> [String: Any] {
            var out: [String: Any] = [
                "addresses": book.addresses.count, "profile": book.hasProfile, "cards": book.cards.map(\.title),
            ]
            if let preview = forms.preview {
                out["summary"] = preview.plan.summary
                out["note"] = preview.plan.note ?? ""
                out["rows"] = preview.plan.rows.map { ["kind": $0.kind?.rawValue ?? "", "shown": $0.shown, "source": $0.source.rawValue] }
            }
            if let done = forms.done { out["done"] = ["filled": done.filled, "stays": done.stays] }
            if let report = forms.lastReport { out["report"] = ["filled": report.filled, "missed": report.missed] }
            return out
        }
        switch request["action"] as? String {
        case "seed":
            var profile = AutofillProfile()
            profile.name = "Test Person"
            profile.email = "test@example.com"
            profile.phone = "+1 555 0100"
            profile.company = "Test Company"
            book.save(profile: profile)
            book.save(address: AutofillAddress(label: "Test home", line1: "1 Test Street", line2: "Unit 2", city: "Testville",
                                               region: "CA", postal: "94000", country: "United States"))
            if let expiry = CardExpiry(month: 12, year: 2031) {
                book.save(card: CardSecret(number: "4242424242424242", expiry: expiry, holder: "Test Person"), label: "Test")
            }
            answer(state())
        case "clear":
            book.save(profile: AutofillProfile())
            book.addresses.forEach { book.forget(address: $0.id) }
            book.cards.forEach { book.forget(card: $0.id) }
            forms.cancel()
            answer(state())
        case "preview":
            guard let tab = browser.active, let page = forms.pageFor(tab) else { answer(["error": "no page"]); return }
            Task { @MainActor in
                await forms.prepare(tab, page)
                answer(state())
            }
        case "fill":
            forms.confirm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(state()) }
        case "undo":
            forms.undo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { answer(state()) }
        case "cancel":
            forms.cancel()
            answer(state())
        default:
            answer(state())
        }
    }

    func codes(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let watch = browser.codeWatch
        func state() -> [String: Any] {
            var out: [String: Any] = ["reads": watch.reads]
            out["offered"] = watch.offered.map { ["sender": $0.sender, "length": $0.code.count] }
            out["rows"] = browser.suggesting?.codes.count ?? 0
            out["said"] = browser.announcement ?? ""
            out["codeBox"] = browser.active?.focusedField.map(FormClassifier.isCode) ?? false
            return out
        }
        switch request["action"] as? String {
        case "fake":
            let source = BenchCodes(text: request["text"] as? String ?? "", sender: request["sender"] as? String ?? "")
            watch.sources = { _ in [source] }
            answer(state())
        case "none":
            watch.sources = { _ in [] }
            watch.stop()
            answer(state())
        case "use":
            if let first = browser.suggesting?.codes.first { browser.choose(first) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { answer(state()) }
        default:
            answer(state())
        }
    }
}

final class BenchCodes: CodeSource {
    private let text: String
    private let sender: String

    init(text: String, sender: String) {
        self.text = text
        self.sender = sender
    }

    func read(since: Date) async -> CodeRead {
        guard let code = CodeFinder.code(in: text) else { return .nothing }
        return .found([OneTimeCode(code: code, sender: sender, at: Date())])
    }
}
