import Foundation

struct FieldAnswer: Equatable {
    enum Kind: String { case sum, base, unit, time, date, currency }
    let kind: Kind
    let expression: String
    let answer: String
    let copy: String
    var detail = ""

    var full: String { expression + " = " + copy }
}

enum FieldAnswers {
    static let longest = 120

    static func answer(for typed: String, locale: Locale = .autoupdatingCurrent, now: Date = Date(),
                       zone: TimeZone = .autoupdatingCurrent) -> FieldAnswer? {
        let shown = typed.split(whereSeparator: FieldAnswers.isSpace).joined(separator: " ")
        guard !shown.isEmpty, shown.count <= longest, !shown.contains("://"),
              !shown.lowercased().hasPrefix("www.")
        else { return nil }
        let text = normalized(shown)
        guard !text.isEmpty else { return nil }
        let russian = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let context = AnswerContext(locale: locale, russian: russian, now: now, zone: zone)
        if let time = FieldTimes.answer(text, expression: shown, context: context) { return time }
        if let date = FieldDates.answer(text, expression: shown, context: context) { return date }
        guard text.contains(where: \.isNumber) else { return nil }
        if let base = base(text, expression: shown, context: context) { return base }
        if let unit = FieldUnits.answer(text, expression: shown, context: context) { return unit }
        return sum(text, expression: shown, context: context)
    }

    static func normalized(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"(?<![A-Za-z])([KMG])b(?![A-Za-z])"#, with: "$1bit", options: .regularExpression).lowercased()
        for (from, to) in [("−", "-"), ("–", "-"), ("×", "*"), ("÷", "/"), ("**", "^"), ("·", "*"),
                           ("→", " → "), ("->", " → "), ("⇒", " → ")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        for lead in ["what is ", "what's ", "whats ", "calculate ", "сколько будет ", "посчитай ", "вычисли "]
        where out.hasPrefix(lead) {
            out.removeFirst(lead.count)
        }
        while let last = out.last, last == "=" || last == "?" || last == " " { out.removeLast() }
        return out.split(whereSeparator: isSpace).joined(separator: " ")
    }

    static func isSpace(_ char: Character) -> Bool { char == " " || char == "\t" || char == "\n" || char == "\r" }

    static let connectors: Set<String> = ["in", "to", "into", "as", "→", "=", "в", "во"]

    static func splits(_ text: String) -> [(left: String, right: String)] {
        let words = text.split(separator: " ").map(String.init)
        return words.indices.compactMap { index in
            guard connectors.contains(words[index]), index > 0, index < words.count - 1 else { return nil }
            return (words[..<index].joined(separator: " "), words[(index + 1)...].joined(separator: " "))
        }
    }

    static func sum(_ text: String, expression: String, context: AnswerContext) -> FieldAnswer? {
        guard !looksLikeDateOrPhone(text) else { return nil }
        guard let tokens = AnswerLexer.tokens(text, locale: context.locale) else { return nil }
        if tokens.count == 1, case .number(let value, let radix?) = tokens[0], radix != 10 {
            return based(value, as: 10, expression: expression, context: context)
        }
        var parser = AnswerParser(tokens: tokens)
        guard let value = parser.whole(), parser.operations > 0 else { return nil }
        let number = value.percent ? value.number * 100 : value.number
        let numbers = AnswerNumbers(locale: context.locale)
        guard let shown = numbers.string(number, grouped: true), let copy = numbers.string(number, grouped: false)
        else { return nil }
        let mark = value.percent ? "%" : ""
        return FieldAnswer(kind: .sum, expression: expression, answer: shown + mark, copy: copy + mark)
    }

    static func looksLikeDateOrPhone(_ text: String) -> Bool {
        let shapes = [#"^\d{4}-\d{1,2}-\d{1,2}$"#, #"^\d{1,2}[./-]\d{1,2}[./-]\d{2,4}$"#, #"^\+?\d+(-\d+){2,}$"#,
                      #"^\+\d[\d ()-]*$"#]
        return shapes.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static let radixes: [(stems: [String], exact: [String], radix: Int)] = [
        (["hexadecimal", "шестнадцатеричн", "16-ричн"], ["hex", "base16", "base 16", "хекс"], 16),
        (["decimal", "десятичн", "10-ричн"], ["dec", "base10", "base 10"], 10),
        (["binary", "двоичн", "2-ичн"], ["bin", "base2", "base 2"], 2),
        (["octal", "восьмеричн", "8-ричн"], ["oct", "base8", "base 8"], 8),
    ]

    static func radix(named phrase: String) -> Int? {
        var words = phrase.split(separator: " ").map(String.init)
        let filler: Set<String> = ["система", "системе", "систему", "системы", "счисления", "system", "notation"]
        while let last = words.last, filler.contains(last), words.count > 1 { words.removeLast() }
        let name = words.joined(separator: " ")
        for entry in radixes {
            if entry.exact.contains(name) { return entry.radix }
            if words.count == 1, entry.stems.contains(where: { name.hasPrefix($0) && name.count - $0.count <= 3 }) {
                return entry.radix
            }
        }
        return nil
    }

    static func base(_ text: String, expression: String, context: AnswerContext) -> FieldAnswer? {
        for (left, right) in splits(text).reversed() {
            guard let radix = radix(named: right),
                  let tokens = AnswerLexer.tokens(left, locale: context.locale) else { continue }
            var parser = AnswerParser(tokens: tokens)
            guard let value = parser.whole(), !value.percent else { continue }
            return based(value.number, as: radix, expression: expression, context: context)
        }
        return nil
    }

    static func based(_ value: Double, as radix: Int, expression: String, context: AnswerContext) -> FieldAnswer? {
        guard value.isFinite, value.rounded() == value, abs(value) < 9.007_199_254_740_992e15 else { return nil }
        let whole = Int64(value)
        let sign = whole < 0 ? "-" : ""
        let size = whole.magnitude
        let text: String
        switch radix {
        case 16: text = sign + "0x" + String(size, radix: 16).uppercased()
        case 2: text = sign + "0b" + String(size, radix: 2)
        case 8: text = sign + "0o" + String(size, radix: 8)
        default:
            let numbers = AnswerNumbers(locale: context.locale)
            guard let shown = numbers.string(value, grouped: true), let copy = numbers.string(value, grouped: false)
            else { return nil }
            return FieldAnswer(kind: .base, expression: expression, answer: shown, copy: copy)
        }
        return FieldAnswer(kind: .base, expression: expression, answer: text, copy: text)
    }
}

enum AnswerFormatters {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [Key: DateFormatter] = [:]
    private static let watch: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
    ) { _ in AnswerFormatters.forget() }

    struct Key: Hashable {
        let kind: String
        let locale: Locale
        let localeName: String
        let zone: TimeZone
        let zoneName: String
        let template: String

        init(_ kind: String, locale: Locale, zone: TimeZone, template: String) {
            self.kind = kind
            self.locale = locale
            localeName = locale.identifier
            self.zone = zone
            zoneName = zone.identifier
            self.template = template
        }
    }

    static func formatter(_ key: Key, make: () -> DateFormatter) -> DateFormatter {
        _ = watch
        lock.lock()
        defer { lock.unlock() }
        if let known = made[key] { return known }
        if made.count > 256 { made.removeAll() }
        let formatter = make()
        made[key] = formatter
        return formatter
    }

    static func forget() {
        lock.lock()
        made.removeAll()
        lock.unlock()
    }
}

struct AnswerContext {
    let locale: Locale
    let russian: Bool
    let now: Date
    let zone: TimeZone

    var wordsLocale: Locale { russian ? Locale(identifier: "ru_RU") : locale }
}

struct AnswerNumbers {
    let locale: Locale
    var significant = 12

    func string(_ value: Double, grouped: Bool) -> String? {
        guard value.isFinite else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        let size = abs(value)
        if size != 0, size >= 1e15 || size < 1e-9 {
            formatter.numberStyle = .scientific
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = min(significant, 10)
            formatter.exponentSymbol = "e"
            return formatter.string(from: value as NSNumber)
        }
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouped
        formatter.roundingMode = .halfEven
        let whole = size < 1 ? 0 : Int(log10(size).rounded(.down)) + 1
        let zeros = size > 0 && size < 1 ? Int((-log10(size)).rounded(.up)) - 1 : 0
        formatter.maximumFractionDigits = min(15, max(0, significant - whole + zeros))
        formatter.minimumFractionDigits = 0
        guard let text = formatter.string(from: value as NSNumber) else { return nil }
        return text == "-0" ? "0" : text
    }
}

enum AnswerToken: Equatable {
    case number(Double, radix: Int?)
    case op(Character)
    case open
    case close
    case percent
    case word(String)
}

enum AnswerLexer {
    static let separators: Set<Character> = [".", ",", "\u{00A0}", "\u{202F}"]

    static func tokens(_ text: String, locale: Locale) -> [AnswerToken]? {
        let chars = Array(text)
        var out: [AnswerToken] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == " " {
                index += 1
            } else if char.isASCII, char.isNumber || (char == "." && index + 1 < chars.count && chars[index + 1].isASCII && chars[index + 1].isNumber) {
                guard let (value, radix, end) = number(chars, from: index, locale: locale) else { return nil }
                out.append(.number(value, radix: radix))
                index = end
            } else if "+-*/^".contains(char) {
                out.append(.op(char))
                index += 1
            } else if char == "(" {
                out.append(.open)
                index += 1
            } else if char == ")" {
                out.append(.close)
                index += 1
            } else if char == "%" {
                out.append(.percent)
                index += 1
            } else if char == "√" || char == "π" {
                out.append(.word(String(char)))
                index += 1
            } else if char.isLetter {
                var end = index
                while end < chars.count, chars[end].isLetter, chars[end] != "π" { end += 1 }
                out.append(.word(String(chars[index..<end])))
                index = end
            } else {
                return nil
            }
            if out.count > 80 { return nil }
        }
        return out
    }

    static func number(_ chars: [Character], from start: Int, locale: Locale) -> (Double, Int?, Int)? {
        if chars[start] == "0", start + 1 < chars.count, let radix = ["x": 16, "b": 2, "o": 8][chars[start + 1]] {
            var end = start + 2
            while end < chars.count, chars[end].isASCII, chars[end].isHexDigit, chars[end].hexDigitValue! < radix { end += 1 }
            guard end > start + 2, end - start - 2 <= 16 else { return nil }
            if end < chars.count, chars[end].isLetter || chars[end].isNumber { return nil }
            guard let value = UInt64(String(chars[(start + 2)..<end]), radix: radix), value < 1 << 53 else { return nil }
            return (Double(value), radix, end)
        }
        var end = start
        while end < chars.count {
            let char = chars[end]
            if char.isASCII, char.isNumber {
                end += 1
            } else if separators.contains(char), end + 1 < chars.count, chars[end + 1].isASCII, chars[end + 1].isNumber {
                end += 1
            } else {
                break
            }
        }
        guard let value = decimal(String(chars[start..<end]), locale: locale) else { return nil }
        return (value, nil, end)
    }

    static func decimal(_ raw: String, locale: Locale) -> Double? {
        let point = locale.decimalSeparator ?? "."
        let group = locale.groupingSeparator ?? ","
        var text = raw
        for space in ["\u{00A0}", "\u{202F}"] where text.contains(space) {
            guard grouped(text, by: Character(space)) else { return nil }
            text = text.replacingOccurrences(of: space, with: "")
        }
        let dots = text.filter { $0 == "." }.count
        let commas = text.filter { $0 == "," }.count
        var digits: String
        switch (dots, commas) {
        case (0, 0):
            digits = text
        case (_, _) where dots > 0 && commas > 0:
            let lastDot = text.lastIndex(of: ".")!
            let lastComma = text.lastIndex(of: ",")!
            let decimalMark: Character = lastDot > lastComma ? "." : ","
            let groupMark: Character = decimalMark == "." ? "," : "."
            guard text.filter({ $0 == decimalMark }).count == 1 else { return nil }
            let parts = text.split(separator: decimalMark, omittingEmptySubsequences: false)
            guard grouped(String(parts[0]), by: groupMark) else { return nil }
            digits = parts[0].replacingOccurrences(of: String(groupMark), with: "") + "." + parts[1]
        case (0, 1):
            digits = commaOrDot(text, mark: ",", point: point, group: group)
        case (1, 0):
            digits = commaOrDot(text, mark: ".", point: point, group: group)
        case (0, _):
            guard grouped(text, by: ",") else { return nil }
            digits = text.replacingOccurrences(of: ",", with: "")
        default:
            guard group == ".", grouped(text, by: ".") else { return nil }
            digits = text.replacingOccurrences(of: ".", with: "")
        }
        if digits.hasPrefix(".") { digits = "0" + digits }
        return Double(digits)
    }

    private static func commaOrDot(_ text: String, mark: Character, point: String, group: String) -> String {
        let parts = text.split(separator: mark, omittingEmptySubsequences: false)
        let groupsLikeThousands = parts[1].count == 3 && (1...3).contains(parts[0].count) && parts[0].first != "0"
        if point == String(mark) || !(group == String(mark) && groupsLikeThousands) {
            return parts[0] + "." + parts[1]
        }
        return String(parts[0] + parts[1])
    }

    private static func grouped(_ text: String, by mark: Character) -> Bool {
        let parts = text.split(separator: mark, omittingEmptySubsequences: false)
        guard let first = parts.first, (1...3).contains(first.count) else { return false }
        return parts.dropFirst().allSatisfy { $0.count == 3 }
    }
}

struct AnswerParser {
    struct Value {
        var number: Double
        var percent = false
    }

    private struct Refusal: Error {}

    let tokens: [AnswerToken]
    private var index = 0
    private var depth = 0
    private(set) var operations = 0

    init(tokens: [AnswerToken]) {
        self.tokens = tokens
    }

    mutating func whole() -> Value? {
        guard !tokens.isEmpty, let value = try? expression(), index == tokens.count, value.number.isFinite else {
            return nil
        }
        return value
    }

    private var next: AnswerToken? { index < tokens.count ? tokens[index] : nil }

    private mutating func expression() throws -> Value {
        var left = try term()
        while case .op(let op)? = next, op == "+" || op == "-" {
            index += 1
            let right = try term()
            operations += 1
            if right.percent, !left.percent {
                left = Value(number: left.number * (op == "+" ? 1 + right.number : 1 - right.number))
            } else {
                left = Value(number: op == "+" ? left.number + right.number : left.number - right.number,
                             percent: left.percent && right.percent)
            }
        }
        return left
    }

    private static let times: Set<String> = ["x", "х"]
    private static let of: Set<String> = ["of", "от"]
    private static let off: Set<String> = ["off"]

    private mutating func term() throws -> Value {
        var left = try unary()
        while let token = next {
            switch token {
            case .op("*"):
                index += 1
                left = Value(number: left.number * (try unary()).number)
            case .op("/"):
                index += 1
                let right = try unary()
                guard right.number != 0 else { throw Refusal() }
                left = Value(number: left.number / right.number)
            case .word(let word) where Self.times.contains(word):
                index += 1
                left = Value(number: left.number * (try unary()).number)
            case .word(let word) where Self.of.contains(word):
                guard left.percent else { throw Refusal() }
                index += 1
                left = Value(number: left.number * (try unary()).number)
            case .word(let word) where Self.off.contains(word):
                guard left.percent else { throw Refusal() }
                index += 1
                left = Value(number: (try unary()).number * (1 - left.number))
            default:
                return left
            }
            operations += 1
        }
        return left
    }

    private mutating func unary() throws -> Value {
        if case .op(let op)? = next, op == "-" || op == "+" {
            index += 1
            try deeper()
            defer { depth -= 1 }
            let value = try unary()
            return Value(number: op == "-" ? -value.number : value.number, percent: value.percent)
        }
        return try power()
    }

    private mutating func power() throws -> Value {
        let base = try postfix()
        guard case .op("^")? = next else { return base }
        index += 1
        try deeper()
        defer { depth -= 1 }
        let exponent = try unary()
        let value = pow(base.number, exponent.number)
        guard value.isFinite else { throw Refusal() }
        operations += 1
        return Value(number: value)
    }

    private mutating func postfix() throws -> Value {
        var value = try primary()
        if case .percent? = next {
            guard !value.percent else { throw Refusal() }
            index += 1
            value = Value(number: value.number / 100, percent: true)
        }
        return value
    }

    private mutating func primary() throws -> Value {
        guard let token = next else { throw Refusal() }
        index += 1
        switch token {
        case .number(let value, _):
            return Value(number: value)
        case .open:
            try deeper()
            defer { depth -= 1 }
            let value = try expression()
            guard case .close? = next else { throw Refusal() }
            index += 1
            return value
        case .word(let word) where word == "pi" || word == "π" || word == "пи":
            return Value(number: .pi)
        case .word(let word) where word == "sqrt" || word == "√" || word == "корень":
            try deeper()
            defer { depth -= 1 }
            let value = try postfix()
            guard value.number >= 0, !value.percent else { throw Refusal() }
            operations += 1
            return Value(number: value.number.squareRoot())
        default:
            throw Refusal()
        }
    }

    private mutating func deeper() throws {
        depth += 1
        guard depth <= 32 else { throw Refusal() }
    }
}
