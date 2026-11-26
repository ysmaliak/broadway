import AppKit
import CryptoKit
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.ysmaliak.broadway", category: "Form answers")

struct FormAnswer: Codable, Equatable {
    var value: String
    var text: String
}

enum FormMemory {
    static let longest = 120
    static let help = "Remembered from this site"
    private static let types: Set<String> = ["text", "email", "tel", "number", "url", "date", "datetime-local", "month", "week", "time", "select"]
    private static let refused: Set<String> = ["off", "one-time-code", "new-password", "current-password"]

    static func site(of page: URL?) -> String? {
        guard let page, let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = page.host()?.lowercased(), !host.isEmpty
        else { return nil }
        return Vault.registrable(host)
    }

    static func meaning(_ field: FormField) -> String? {
        func plain(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let label = plain(field.label.isEmpty ? field.placeholder : field.label)
        let name = plain(field.name.isEmpty ? field.htmlID : field.name)
        guard !label.isEmpty || !name.isEmpty else { return nil }
        return label + "\u{1}" + name
    }

    static func eligible(_ field: FormField) -> Bool {
        guard types.contains(field.type) else { return false }
        if field.autocomplete.split(separator: " ").contains(where: { refused.contains(String($0)) }) { return false }
        if field.name.lowercased() == "q" || field.words.range(of: #"\bsearch\b"#, options: .regularExpression) != nil { return false }
        switch FormClassifier.verdict(field) {
        case .ignored: return false
        case .fill(let kind): return !kind.isCard
        case .stay(let stay): return ![.secret, .code, .consent].contains(stay)
        }
    }

    static func answer(_ field: FormField, value: String) -> FormAnswer? {
        guard eligible(field), meaning(field) != nil else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= longest, !trimmed.contains(where: \.isNewline), !CardNumber.valid(trimmed) else { return nil }
        guard field.type == "select" else { return FormAnswer(value: trimmed, text: trimmed) }
        guard let option = field.options.first(where: { $0.value == value }), !option.value.isEmpty else { return nil }
        let text = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FormAnswer(value: option.value, text: text.isEmpty ? option.value : text)
    }

    static func fill(_ answer: FormAnswer, into field: FormField) -> (value: String, shown: String)? {
        guard field.type == "select" else {
            guard field.maxLength == 0 || answer.value.count <= field.maxLength else { return nil }
            return (answer.value, answer.value)
        }
        let wanted = answer.text.lowercased()
        let option = field.options.first { !$0.value.isEmpty && $0.value == answer.value }
            ?? field.options.first { !$0.value.isEmpty && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }
        guard let option else { return nil }
        return (option.value, option.text.isEmpty ? option.value : option.text)
    }

    static func taken(_ fields: [FormField], values: [String: String]) -> [String: FormAnswer] {
        var out: [String: FormAnswer] = [:]
        for field in fields {
            guard let value = values[field.id], let meaning = meaning(field), let answer = answer(field, value: value) else { continue }
            out[meaning] = answer
        }
        return out
    }
}

@MainActor
@Observable
final class FormAnswers {
    struct Site: Codable, Equatable {
        var used: Date
        var answers: [String: FormAnswer]
    }

    static let shared = FormAnswers(file: Store.file("form-answers"), keeper: AutofillBook.shared.keeper)
    static let mostSites = 500
    static let mostPerSite = 200
    private static let keyID = "form-answers"

    private(set) var sites: [String: Site] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let keeper: AutofillKeeper
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(file: URL, keeper: AutofillKeeper) {
        self.file = file
        self.keeper = keeper
    }

    var siteCount: Int { sites.count }

    func ready() async {
        if let loading { return await loading.value }
        let made = Task { await load() }
        loading = made
        await made.value
    }

    private func load() async {
        let turn = generation
        let kept = await keeper.fetch(.answers, id: Self.keyID)
        guard turn == generation else { return }
        if let kept, kept.count == 32 { key = SymmetricKey(data: kept) }
        guard let key, let sealed = try? Data(contentsOf: file) else { return }
        guard let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key),
              let read = try? JSONDecoder().decode([String: Site].self, from: plain)
        else {
            Store.quarantine(file)
            return
        }
        sites = read.merging(sites) { _, newer in newer }
    }

    func answers(for page: URL?) -> [String: FormAnswer] {
        guard let site = FormMemory.site(of: page) else { return [:] }
        return sites[site]?.answers ?? [:]
    }

    func answer(for field: FormField, on page: URL?) -> FormAnswer? {
        guard FormMemory.eligible(field), let meaning = FormMemory.meaning(field) else { return nil }
        return answers(for: page)[meaning]
    }

    func remember(_ taken: [String: FormAnswer], on page: URL?, now: Date = Date()) async {
        guard !taken.isEmpty, let site = FormMemory.site(of: page) else { return }
        await ready()
        var entry = sites[site] ?? Site(used: now, answers: [:])
        entry.used = now
        entry.answers.merge(taken) { _, new in new }
        if entry.answers.count > Self.mostPerSite {
            entry.answers = Dictionary(uniqueKeysWithValues: entry.answers.sorted { $0.key < $1.key }.suffix(Self.mostPerSite).map { ($0.key, $0.value) })
        }
        var next = sites
        next[site] = entry
        if next.count > Self.mostSites {
            for old in next.sorted(by: { $0.value.used < $1.value.used }).prefix(next.count - Self.mostSites) where old.key != site {
                next[old.key] = nil
            }
        }
        sites = next
        save()
    }

    static func sitesLine(_ count: Int) -> String {
        switch count {
        case 0: "Nothing remembered yet"
        case 1: "1 site"
        default: "\(count) sites"
        }
    }

    static func question(_ count: Int) -> String { SettingsQuestion.answers(count).title }

    static func askToForgetAll(_ answers: FormAnswers, over window: NSWindow? = nil, then: @escaping () -> Void = {}) {
        SettingsQuestion.answers(answers.siteCount).ask(over: window) {
            answers.forgetAll()
            then()
        }
    }

    func forgetAll() {
        generation += 1
        loading = Task {}
        sites = [:]
        try? FileManager.default.removeItem(at: file)
    }

    private func sealingKey() -> SymmetricKey? {
        if let key { return key }
        let made = SymmetricKey(size: .bits256)
        let raw = made.withUnsafeBytes { Data($0) }
        guard keeper.write(.answers, id: Self.keyID, note: "", data: raw) else { return nil }
        key = made
        return made
    }

    private func save() {
        guard !sites.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard let key = sealingKey(), let plain = try? JSONEncoder().encode(sites),
              let sealed = try? AES.GCM.seal(plain, using: key).combined
        else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            log.notice("couldn't be saved")
        }
    }
}
