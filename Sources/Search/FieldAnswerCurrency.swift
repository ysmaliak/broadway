import Foundation

struct CurrencyQuestion: Equatable {
    let expression: String
    let amount: Double
    let from: String
    let to: String
}

enum FieldCurrency {
    static let codes: Set<String> = Set("EUR USD JPY CZK DKK GBP HUF PLN RON SEK CHF ISK NOK TRY AUD BRL CAD CNY HKD IDR ILS INR KRW MXN MYR NZD PHP SGD THB ZAR RUB BGN".split(separator: " ").map(String.init))
    static let aliases: [String: String] = [
        "€": "EUR", "euro": "EUR", "euros": "EUR", "евро": "EUR",
        "$": "USD", "us dollar": "USD", "us dollars": "USD", "dollar": "USD", "dollars": "USD",
        "доллар": "USD", "доллара": "USD", "долларов": "USD", "доллары": "USD", "долл": "USD",
        "zł": "PLN", "zl": "PLN", "zloty": "PLN", "zlotys": "PLN", "zlotych": "PLN",
        "злотый": "PLN", "злотых": "PLN", "злотые": "PLN", "злотого": "PLN",
        "£": "GBP", "pound": "GBP", "pounds": "GBP", "фунт": "GBP", "фунта": "GBP", "фунтов": "GBP",
        "₽": "RUB", "руб": "RUB", "руб.": "RUB", "рубль": "RUB", "рубля": "RUB", "рублей": "RUB",
        "rouble": "RUB", "roubles": "RUB", "ruble": "RUB", "rubles": "RUB",
        "yen": "JPY", "иен": "JPY", "иена": "JPY", "иены": "JPY", "юань": "CNY", "юаней": "CNY", "юаня": "CNY",
    ]

    static func code(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias = aliases[name] { return alias }
        let upper = name.uppercased()
        return codes.contains(upper) ? upper : nil
    }

    static func question(_ typed: String, locale: Locale = .autoupdatingCurrent) -> CurrencyQuestion? {
        let shown = typed.split(whereSeparator: FieldAnswers.isSpace).joined(separator: " ")
        guard !shown.isEmpty, shown.count <= FieldAnswers.longest, !shown.contains("://") else { return nil }
        let text = FieldAnswers.normalized(shown)
        for (left, right) in FieldAnswers.splits(text).reversed() {
            guard let to = code(right) else { continue }
            if let (amount, from) = amount(left, locale: locale) {
                return CurrencyQuestion(expression: shown, amount: amount, from: from, to: to)
            }
        }
        return nil
    }

    static func isQuery(_ typed: String, locale: Locale = .autoupdatingCurrent) -> Bool {
        let text = FieldAnswers.normalized(typed)
        guard !text.isEmpty, text.count <= FieldAnswers.longest else { return false }
        if question(typed, locale: locale) != nil || amount(text, locale: locale) != nil { return true }
        if FieldAnswers.splits(text).contains(where: { amount($0.left, locale: locale) != nil }) { return true }
        return FieldAnswers.connectors.contains { connector in
            text.hasSuffix(" " + connector) && amount(String(text.dropLast(connector.count + 1)), locale: locale) != nil
        }
    }

    private static let names = (Array(aliases.keys) + codes.map { $0.lowercased() }).sorted { $0.count > $1.count }

    private static func amount(_ left: String, locale: Locale) -> (Double, String)? {
        for name in names {
            let amount: String
            if left.hasSuffix(name) { amount = String(left.dropLast(name.count)).trimmingCharacters(in: .whitespaces) }
            else if left.hasPrefix(name) { amount = String(left.dropFirst(name.count)).trimmingCharacters(in: .whitespaces) }
            else { continue }
            guard let from = code(name), let tokens = AnswerLexer.tokens(amount, locale: locale), tokens.count == 1,
                  case .number(let value, let radix) = tokens[0], radix == nil || radix == 10,
                  value.isFinite, value >= 0 else { continue }
            return (value, from)
        }
        return nil
    }

    static func answer(_ question: CurrencyQuestion, rates: ECBRates?, locale: Locale = .autoupdatingCurrent) -> FieldAnswer? {
        guard let rates, rates.valid, let source = rates.values[question.from], let target = rates.values[question.to] else { return nil }
        let value = question.amount / source * target
        let numbers = AnswerNumbers(locale: locale, significant: 8)
        guard let shown = numbers.string(value, grouped: true), let copy = numbers.string(value, grouped: false) else { return nil }
        return FieldAnswer(kind: .currency, expression: question.expression, answer: shown + " " + question.to,
                           copy: copy + " " + question.to, detail: "ECB rate of " + rates.date)
    }
}

struct ECBRates: Codable, Equatable {
    let date: String
    let values: [String: Double]

    var valid: Bool {
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let day = Self.formatter.date(from: date), Self.formatter.string(from: day) == date,
              values["EUR"] == 1, values.count > 1 else { return false }
        return values.allSatisfy { FieldCurrency.codes.contains($0.key) && $0.value.isFinite && $0.value > 0 }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    static func parse(_ data: Data) -> ECBRates? {
        guard data.count <= 65_536 else { return nil }
        let delegate = ECBXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let date = delegate.date else { return nil }
        let rates = ECBRates(date: date, values: delegate.values)
        return rates.valid ? rates : nil
    }
}

private final class ECBXML: NSObject, XMLParserDelegate {
    var date: String?
    var values: [String: Double] = ["EUR": 1]
    var invalid = false
    private var depth = 0
    private var dayDepth: Int?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        guard elementName == "Cube" else { return }
        if let day = attributes["time"] {
            guard date == nil else { invalid = true; return }
            date = day
            dayDepth = depth
        }
        if let currency = attributes["currency"] {
            guard dayDepth == depth - 1, let text = attributes["rate"], let rate = Double(text), rate.isFinite, rate > 0,
                  values[currency] == nil else { invalid = true; return }
            if FieldCurrency.codes.contains(currency) { values[currency] = rate }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if depth == dayDepth { dayDepth = nil }
        depth -= 1
    }
}

struct CurrencyCache: Codable {
    var rates: ECBRates?
    var attemptedAt: Date?

    func due(at now: Date) -> Bool {
        guard let attemptedAt else { return true }
        return now.timeIntervalSince(attemptedAt) >= 6 * 60 * 60
    }
}

@MainActor
final class CurrencyRates {
    static var shared = CurrencyRates()
    static let endpoint = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    private(set) var cache: CurrencyCache
    private let file: URL
    private let fetch: () async throws -> Data
    private var task: Task<ECBRates?, Never>?

    var refreshing: Bool { task != nil }

    init(file: URL = Store.file("currency-rates.json"), fetch: (() async throws -> Data)? = nil) {
        self.file = file
        cache = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CurrencyCache.self, from: $0) } ?? CurrencyCache()
        if cache.rates?.valid == false { cache.rates = nil }
        self.fetch = fetch ?? Self.download
    }

    @discardableResult
    func refresh(now: Date = Date()) async -> Bool {
        if let task { return await task.value != nil }
        guard cache.due(at: now) else { return false }
        cache.attemptedAt = now
        save()
        let fetch = self.fetch
        let current = Task { () -> ECBRates? in
            defer { self.task = nil }
            guard let data = try? await fetch(), let rates = ECBRates.parse(data) else { return nil }
            self.cache.rates = rates
            self.save()
            return rates
        }
        task = current
        return await current.value != nil
    }

    private func save() {
        let snapshot = cache
        Disk.write(file, now: true) { try? JSONEncoder().encode(snapshot) }
    }

    private static func download() async throws -> Data {
        let endpoint: URL
        if Store.testing {
            guard let text = Store.settings.string(forKey: "currency.testURL"), let test = URL(string: text),
                  test.scheme == "http", ["127.0.0.1", "localhost"].contains(test.host ?? "") else { throw URLError(.unsupportedURL) }
            endpoint = test
        } else { endpoint = Self.endpoint }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: CurrencyNetwork(), delegateQueue: nil)
    }()
}

private final class CurrencyNetwork: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
