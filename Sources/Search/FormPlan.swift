import Foundation

struct FormSources {
    var profile = AutofillProfile()
    var address: AutofillAddress?
    var card: CardRow?
    var remembered: [String: FormAnswer] = [:]
}

struct FormPlanRow: Equatable, Identifiable {
    let field: FormField
    let kind: FormValueKind?
    let source: FormSource
    let value: String?
    let shown: String

    var id: String { field.id }
}

struct FormPlan: Equatable {
    var rows: [FormPlanRow] = []
    var fields: [FormField] = []
    var total = 0
    var note: String?

    var stays: Int { total - rows.count }
    var summary: String {
        stays == 0 ? "\(rows.count) of \(total)" : "\(rows.count) of \(total) · \(stays) stay yours"
    }
    var needsCard: Bool { rows.contains { $0.kind?.isCard == true } }
}

enum FormFrames {
    private static let processors = ["js.stripe.com", "braintreegateway.com", "adyen.com"]

    static func allowed(_ field: FormField, kind: FormValueKind?, page: URL?) -> Bool {
        guard !field.frame.isEmpty else { return true }
        guard let host = URLComponents(string: field.origin)?.host?.lowercased(), let pageHost = page?.host()?.lowercased(),
              field.origin.lowercased().hasPrefix("https://")
        else { return false }
        if Vault.registrable(host) == Vault.registrable(pageHost) { return true }
        guard kind?.isCard == true else { return false }
        return processors.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

enum FormOptions {
    private static let english = Locale(identifier: "en_US")

    private static func plain(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .folding(options: .diacriticInsensitive, locale: english)
    }

    private static func regionCode(for name: String) -> String? {
        let wanted = plain(name)
        if wanted.count == 2 { return wanted.uppercased() }
        return Locale.Region.isoRegions.first { region in
            english.localizedString(forRegionCode: region.identifier).map(plain) == wanted
        }?.identifier
    }

    static func pick(_ value: String, kind: FormValueKind, in options: [FormField.Option]) -> String? {
        let wanted = plain(value)
        guard !wanted.isEmpty else { return nil }
        if let exact = options.first(where: { !$0.value.isEmpty && (plain($0.text) == wanted || plain($0.value) == wanted) }) {
            return exact.value
        }
        if kind == .country, let code = regionCode(for: value) {
            let name = english.localizedString(forRegionCode: code).map(plain)
            return options.first { !$0.value.isEmpty && ($0.value.uppercased() == code || plain($0.text) == name) }?.value
        }
        if kind == .cardExpiryMonth, let month = Int(wanted) {
            return options.first { Int(plain($0.value)) == month || Int(plain($0.text).prefix(2)) == month }?.value
        }
        if kind == .cardExpiryYear, let year = Int(wanted) {
            return options.first { Int(plain($0.value)).map { $0 == year || 2000 + $0 == year } ?? false }?.value
        }
        return nil
    }
}

enum FormPlanner {
    static func plan(_ fields: [FormField], page: URL?, privateTab: Bool, sources: FormSources) -> FormPlan {
        let judged = fields.compactMap { field -> (FormField, FieldVerdict)? in
            let verdict = FormClassifier.verdict(field)
            if verdict == .ignored { return nil }
            var kind: FormValueKind?
            if case .fill(let filled) = verdict { kind = filled }
            return FormFrames.allowed(field, kind: kind, page: page) ? (field, verdict) : nil
        }
        let group = chosenGroup(judged, remembered: sources.remembered)
        let scope = judged.filter { !$0.0.frame.isEmpty || $0.0.group == group }
        let cardRule = CardRules.fill(on: page, privateTab: privateTab)
        let card = cardRule == .refused ? nil : sources.card

        var plan = FormPlan(total: scope.count)
        plan.fields = scope.map(\.0)
        var sawCardBox = false
        for (field, verdict) in scope {
            if case .fill(let kind) = verdict, kind.isCard { sawCardBox = true }
            guard !field.filled else { continue }
            if case .fill(let kind) = verdict, let row = row(field, kind: kind, sources: sources, card: card) {
                plan.rows.append(row)
            } else if let row = remembered(field, sources.remembered) {
                plan.rows.append(row)
            }
        }
        if sawCardBox, cardRule == .refused, sources.card != nil { plan.note = "Cards are never filled on an insecure page" }
        return plan
    }

    private static func chosenGroup(_ judged: [(FormField, FieldVerdict)], remembered: [String: FormAnswer]) -> Int {
        let main = judged.filter { $0.0.frame.isEmpty }
        if let focused = main.first(where: { $0.0.focused }) { return focused.0.group }
        var counts: [Int: Int] = [:]
        for (field, verdict) in main {
            if case .fill = verdict {
                counts[field.group, default: 0] += 1
            } else if !remembered.isEmpty, FormMemory.eligible(field), let meaning = FormMemory.meaning(field), remembered[meaning] != nil {
                counts[field.group, default: 0] += 1
            }
        }
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 0
    }

    private static func remembered(_ field: FormField, _ answers: [String: FormAnswer]) -> FormPlanRow? {
        guard !answers.isEmpty, FormMemory.eligible(field), let meaning = FormMemory.meaning(field),
              let answer = answers[meaning], let filled = FormMemory.fill(answer, into: field)
        else { return nil }
        return FormPlanRow(field: field, kind: nil, source: .remembered, value: filled.value, shown: filled.shown)
    }

    private static func row(_ field: FormField, kind: FormValueKind, sources: FormSources, card: CardRow?) -> FormPlanRow? {
        if kind.isCard {
            guard let card else { return nil }
            if kind == .cardCode, !card.hasCode { return nil }
            return FormPlanRow(field: field, kind: kind, source: .card, value: nil, shown: kind == .cardNumber ? card.title : "••••")
        }
        let (text, source) = personal(kind, sources: sources)
        guard !text.isEmpty else { return nil }
        var value = field.type == "textarea" ? text : text.replacingOccurrences(of: "\n", with: ", ")
        if field.type == "select" {
            guard let option = FormOptions.pick(text, kind: kind, in: field.options) else { return nil }
            value = option
        }
        return FormPlanRow(field: field, kind: kind, source: source, value: value, shown: field.type == "select" ? text : value)
    }

    private static func personal(_ kind: FormValueKind, sources: FormSources) -> (String, FormSource) {
        let profile = sources.profile
        let address = sources.address
        func either(_ first: String?, _ second: String) -> (String, FormSource) {
            if let first, !first.isEmpty { return (first, .address) }
            return (second, .profile)
        }
        let name = either(address?.name, profile.name)
        let parts = name.0.split(separator: " ").map(String.init)
        switch kind {
        case .fullName: return name
        case .givenName: return (parts.first ?? "", name.1)
        case .familyName: return (parts.dropFirst().joined(separator: " "), name.1)
        case .organization: return either(address?.company, profile.company)
        case .jobTitle: return (profile.role, .profile)
        case .email: return (profile.email, .profile)
        case .phone: return either(address?.phone, profile.phone)
        case .street: return (address?.street ?? "", .address)
        case .addressLine1: return (address?.line1 ?? "", .address)
        case .addressLine2: return (address?.line2 ?? "", .address)
        case .city: return (address?.city ?? "", .address)
        case .region: return (address?.region ?? "", .address)
        case .postal: return (address?.postal ?? "", .address)
        case .country: return (address?.country ?? "", .address)
        default: return ("", .profile)
        }
    }

    static func cardValue(_ kind: FormValueKind, field: FormField, card: CardSecret) -> String? {
        let expiry = card.expiry
        switch kind {
        case .cardName: return card.holder.isEmpty ? nil : card.holder
        case .cardNumber: return card.number
        case .cardCode: return card.securityCode.isEmpty ? nil : card.securityCode
        case .cardExpiryMonth:
            return field.type == "select" ? FormOptions.pick(String(expiry.month), kind: kind, in: field.options) : expiry.twoDigitMonth
        case .cardExpiryYear:
            if field.type == "select" { return FormOptions.pick(expiry.fourDigitYear, kind: kind, in: field.options) }
            return field.maxLength == 2 ? expiry.twoDigitYear : expiry.fourDigitYear
        case .cardExpiry:
            let hint = field.placeholder.lowercased()
            if field.maxLength == 4 { return expiry.twoDigitMonth + expiry.twoDigitYear }
            if hint.contains("yyyy") || hint.contains("aaaa") { return "\(expiry.twoDigitMonth)/\(expiry.fourDigitYear)" }
            if hint.contains(" / ") { return "\(expiry.twoDigitMonth) / \(expiry.twoDigitYear)" }
            return "\(expiry.twoDigitMonth)/\(expiry.twoDigitYear)"
        default:
            return nil
        }
    }

    static func values(_ plan: FormPlan, card: CardSecret?) -> [FormValue] {
        plan.rows.compactMap { row in
            if let kind = row.kind, kind.isCard {
                guard let card, let value = cardValue(kind, field: row.field, card: card) else { return nil }
                return FormValue(fieldID: row.field.id, value: value, source: .card)
            }
            return row.value.map { FormValue(fieldID: row.field.id, value: $0, source: row.source) }
        }
    }
}
