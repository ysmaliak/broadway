import Foundation
import Observation
import Combine
import Security

enum AutofillShelf: String, CaseIterable {
    case profile, address, card, answers
}

struct KeptItem: Equatable, Identifiable {
    let id: String
    let note: String
}

extension Optional {
    func asyncMap<Out>(_ change: (Wrapped) async -> Out) async -> Out? {
        switch self {
        case .some(let value): return await change(value)
        case .none: return nil
        }
    }
}

protocol AutofillKeeper: AnyObject {
    func list(_ shelf: AutofillShelf) -> [KeptItem]
    func read(_ shelf: AutofillShelf, id: String) -> Data?
    func fetch(_ shelf: AutofillShelf, id: String) async -> Data?
    @discardableResult func write(_ shelf: AutofillShelf, id: String, note: String, data: Data) -> Bool
    @discardableResult func remove(_ shelf: AutofillShelf, id: String) -> Bool
}

extension AutofillKeeper {
    func fetch(_ shelf: AutofillShelf, id: String) async -> Data? { read(shelf, id: id) }
}

final class MemoryKeeper: AutofillKeeper {
    private var shelves: [AutofillShelf: [String: (note: String, data: Data)]] = [:]
    private(set) var reads = 0

    func list(_ shelf: AutofillShelf) -> [KeptItem] {
        (shelves[shelf] ?? [:]).map { KeptItem(id: $0.key, note: $0.value.note) }.sorted { $0.id < $1.id }
    }

    func read(_ shelf: AutofillShelf, id: String) -> Data? {
        reads += 1
        return shelves[shelf]?[id]?.data
    }

    func write(_ shelf: AutofillShelf, id: String, note: String, data: Data) -> Bool {
        shelves[shelf, default: [:]][id] = (note, data)
        return true
    }

    func remove(_ shelf: AutofillShelf, id: String) -> Bool {
        shelves[shelf]?.removeValue(forKey: id) != nil
    }
}

final class KeychainKeeper: AutofillKeeper, @unchecked Sendable {
    private let keychain: SecKeychain?

    func fetch(_ shelf: AutofillShelf, id: String) async -> Data? {
        await Vault.off { [self] in read(shelf, id: id) }
    }

    init(keychain: SecKeychain? = nil) {
        self.keychain = keychain
    }

    private func service(_ shelf: AutofillShelf) -> String {
        "com.ysmaliak.broadway.autofill.\(shelf.rawValue)" + (Store.world.map { ".\($0)" } ?? "")
    }

    private func query(_ shelf: AutofillShelf, id: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(shelf),
        ]
        if let id { query[kSecAttrAccount as String] = id }
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    func list(_ shelf: AutofillShelf) -> [KeptItem] {
        let (rows, status) = Keychain.list(query(shelf))
        guard let rows else {
            if status != errSecItemNotFound { NSLog("Autofill: keychain list failed (%d)", status) }
            return []
        }
        return rows.compactMap { row in
            guard let id = row[kSecAttrAccount as String] as? String else { return nil }
            return KeptItem(id: id, note: row[kSecAttrComment as String] as? String ?? "")
        }
        .sorted { $0.id < $1.id }
    }

    func read(_ shelf: AutofillShelf, id: String) -> Data? {
        let (data, status) = Keychain.read(query(shelf, id: id))
        guard let data else {
            if status != errSecItemNotFound { NSLog("Autofill: keychain read failed (%d)", status) }
            return nil
        }
        return data
    }

    func write(_ shelf: AutofillShelf, id: String, note: String, data: Data) -> Bool {
        let fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrComment as String: note,
        ]
        var fresh = query(shelf, id: id).merging(fields) { _, new in new }
        fresh[kSecMatchSearchList as String] = nil
        fresh[kSecAttrLabel as String] = "Broadway autofill"
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        if let keychain { fresh[kSecUseKeychain as String] = keychain }
        let put = Keychain.write(query(shelf, id: id), fields, orAdd: fresh)
        if put.status == errSecSuccess { return true }
        NSLog(put.added ? "Autofill: keychain add failed (%d)" : "Autofill: keychain write failed (%d)", put.status)
        return false
    }

    func remove(_ shelf: AutofillShelf, id: String) -> Bool {
        Keychain.delete(query(shelf, id: id)) == errSecSuccess
    }
}

struct AutofillProfile: Codable, Equatable {
    var name = ""
    var email = ""
    var phone = ""
    var company = ""
    var role = ""
    var location = ""
    var links: [String] = []

    var isEmpty: Bool { self == AutofillProfile() }

    var givenName: String { name.split(separator: " ").first.map(String.init) ?? "" }
    var familyName: String {
        let parts = name.split(separator: " ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
    }
}

struct AutofillAddress: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var label = ""
    var name = ""
    var company = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var region = ""
    var postal = ""
    var country = ""
    var phone = ""

    var isEmpty: Bool {
        [name, company, line1, line2, city, region, postal, country, phone].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var title: String {
        let named = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        let place = [city, country].first { !$0.isEmpty }
        return place ?? "Address"
    }

    var street: String { [line1, line2].filter { !$0.isEmpty }.joined(separator: "\n") }
}

@MainActor
@Observable
final class AutofillBook {
    static var rehearsing: Bool { Store.testing || Store.unitTests }
    static let shared = AutofillBook(keeper: rehearsing ? MemoryKeeper() : KeychainKeeper())
    private static let profileID = "me"

    let keeper: AutofillKeeper
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var addresses: [KeptItem] = []
    private(set) var hasProfile = false
    private(set) var cards: [CardRow] = []
    var editing: Editing?
    var fillsForms = Store.settings.object(forKey: "autofill.forms") as? Bool ?? true {
        didSet { Store.settings.set(fillsForms, forKey: "autofill.forms") }
    }
    var codesFromGmail = Store.settings.object(forKey: "codes.gmail") as? Bool ?? true {
        didSet { Store.settings.set(codesFromGmail, forKey: "codes.gmail") }
    }
    @ObservationIgnored var prove: OwnerProof = Owner.prove

    enum Editing: Equatable {
        case profile
        case address(String?)
        case card(String?)
    }

    init(keeper: AutofillKeeper) {
        self.keeper = keeper
        reload()
    }

    func reload() {
        addresses = keeper.list(.address)
        hasProfile = keeper.list(.profile).contains { $0.id == Self.profileID }
        cards = keeper.list(.card).compactMap { item in
            Data(item.note.utf8).isEmpty ? nil : try? decoder.decode(CardRow.self, from: Data(item.note.utf8))
        }
    }

    var profile: AutofillProfile {
        keeper.read(.profile, id: Self.profileID).flatMap { try? decoder.decode(AutofillProfile.self, from: $0) } ?? AutofillProfile()
    }

    @discardableResult
    func save(profile: AutofillProfile) -> Bool {
        defer { reload() }
        if profile.isEmpty {
            keeper.remove(.profile, id: Self.profileID)
            return true
        }
        guard let data = try? encoder.encode(profile) else { return false }
        return keeper.write(.profile, id: Self.profileID, note: "", data: data)
    }

    func fetchedProfile() async -> AutofillProfile {
        await keeper.fetch(.profile, id: Self.profileID).flatMap { try? decoder.decode(AutofillProfile.self, from: $0) } ?? AutofillProfile()
    }

    func address(_ id: String) -> AutofillAddress? {
        keeper.read(.address, id: id).flatMap { try? decoder.decode(AutofillAddress.self, from: $0) }
    }

    func fetched(address id: String) async -> AutofillAddress? {
        await keeper.fetch(.address, id: id).flatMap { try? decoder.decode(AutofillAddress.self, from: $0) }
    }

    @discardableResult
    func save(address: AutofillAddress) -> Bool {
        defer { reload() }
        guard !address.isEmpty, let data = try? encoder.encode(address) else { return false }
        return keeper.write(.address, id: address.id, note: address.title, data: data)
    }

    func forget(address id: String) {
        keeper.remove(.address, id: id)
        reload()
    }

    @discardableResult
    func save(card: CardSecret, label: String = "", id: String = UUID().uuidString) -> Bool {
        defer { reload() }
        guard CardNumber.valid(card.number) else { return false }
        var card = card
        card.number = CardNumber.digits(card.number)
        let row = CardRow(id: id, label: label, network: .of(card.number), last: CardNumber.lastFour(card.number),
                          hasCode: !card.securityCode.isEmpty)
        guard let data = try? encoder.encode(card), let note = try? encoder.encode(row) else { return false }
        return keeper.write(.card, id: id, note: String(decoding: note, as: UTF8.self), data: data)
    }

    func forget(card id: String) {
        keeper.remove(.card, id: id)
        reload()
    }

    func release(card row: CardRow, then: @escaping @MainActor (CardSecret?) -> Void) {
        prove("fill in your \(row.title)") { [weak self] ok in
            guard ok, let self else { return then(nil) }
            Task {
                let data = await self.keeper.fetch(.card, id: row.id)
                then(data.flatMap { try? self.decoder.decode(CardSecret.self, from: $0) })
            }
        }
    }
}
