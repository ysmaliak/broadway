import Foundation
import LocalAuthentication

enum CardNetwork: String, Codable, Equatable {
    case visa, mastercard, amex, discover, diners, jcb, unionpay, other

    var name: String {
        switch self {
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case .amex: return "American Express"
        case .discover: return "Discover"
        case .diners: return "Diners Club"
        case .jcb: return "JCB"
        case .unionpay: return "UnionPay"
        case .other: return "Card"
        }
    }

    static func of(_ number: String) -> CardNetwork {
        let digits = CardNumber.digits(number)
        func starts(_ low: Int, _ high: Int, width: Int) -> Bool {
            guard digits.count >= width, let head = Int(digits.prefix(width)) else { return false }
            return (low...high).contains(head)
        }
        if starts(34, 34, width: 2) || starts(37, 37, width: 2) { return .amex }
        if starts(51, 55, width: 2) || starts(2221, 2720, width: 4) { return .mastercard }
        if starts(300, 305, width: 3) || starts(36, 36, width: 2) || starts(38, 39, width: 2) { return .diners }
        if starts(6011, 6011, width: 4) || starts(644, 649, width: 3) || starts(65, 65, width: 2) { return .discover }
        if starts(3528, 3589, width: 4) { return .jcb }
        if starts(62, 62, width: 2) { return .unionpay }
        if digits.hasPrefix("4") { return .visa }
        return .other
    }
}

enum CardNumber {
    static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }

    static func valid(_ text: String) -> Bool {
        let allowed = text.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" }
        let digits = digits(text)
        guard allowed, (12...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    static func lastFour(_ text: String) -> String { String(digits(text).suffix(4)) }
}

struct CardExpiry: Codable, Equatable {
    var month: Int
    var year: Int

    init?(month: Int, year: Int) {
        guard (1...12).contains(month), (2000...2099).contains(year) else { return nil }
        self.month = month
        self.year = year
    }

    init?(_ text: String) {
        let parts = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard parts.count == 2, parts[1].count == 2 || parts[1].count == 4,
              let month = Int(parts[0]), let year = Int(parts[1])
        else { return nil }
        self.init(month: month, year: parts[1].count == 2 ? 2000 + year : year)
    }

    var twoDigitMonth: String { String(format: "%02d", month) }
    var twoDigitYear: String { String(format: "%02d", year % 100) }
    var fourDigitYear: String { String(year) }
}

struct CardSecret: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var number: String
    var expiry: CardExpiry
    var holder = ""
    var securityCode = ""

    var description: String { "\(CardNetwork.of(number).name) ending \(CardNumber.lastFour(number))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(reflecting: description) }
}

struct CardRow: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var network: CardNetwork
    var last: String
    var hasCode = false

    var title: String { "\(network.name) ···· \(last)" }
}

enum CardRules {
    enum Fill: Equatable { case allowed, askFirst, refused }

    static func fill(on page: URL?, privateTab: Bool) -> Fill {
        guard page?.scheme?.lowercased() == "https" else { return .refused }
        return privateTab ? .askFirst : .allowed
    }

    static func mayOfferToSave(on page: URL?, privateTab: Bool) -> Bool {
        fill(on: page, privateTab: privateTab) == .allowed
    }
}

typealias OwnerProof = @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void

@MainActor
enum Owner {
    static func prove(_ reason: String, _ done: @escaping @MainActor (Bool) -> Void) {
        if AutofillBook.rehearsing { return done(Ask.testing ?? false) }
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            return done(nothingToProve(code(of: trouble)))
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    nonisolated static func code(of trouble: NSError?) -> LAError.Code? {
        guard let trouble else { return nil }
        guard trouble.domain == LAErrorDomain else { return .biometryNotAvailable }
        return LAError.Code(rawValue: trouble.code) ?? .biometryNotAvailable
    }

    nonisolated static func nothingToProve(_ code: LAError.Code?) -> Bool {
        code == .passcodeNotSet
    }

    static func trouble() -> LAError.Code? {
        guard !AutofillBook.rehearsing else { return nil }
        var trouble: NSError?
        guard !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else { return nil }
        let code = code(of: trouble)
        return nothingToProve(code) ? nil : code
    }

    static func cardRefusal() -> String { cardRefused(trouble()) }

    nonisolated static func cardRefused(_ code: LAError.Code?) -> String {
        switch code {
        case nil: "Not filled: your card needs Touch ID"
        case .notInteractive?: "Not filled: the Mac couldn't ask for Touch ID just now"
        default: "Not filled: this Mac can't ask for Touch ID or its password"
        }
    }
}
