import Foundation
import Security

protocol SignInShelf: Sendable {
    func read(_ account: String) -> Data?
    func write(_ data: Data, as account: String) -> Bool
    func remove(_ account: String)
    func accounts() -> [String]
}

struct KeychainShelf: SignInShelf {
    static let service = "Broadway Sign-ins"

    let service: String

    init(service: String = KeychainShelf.service) {
        self.service = service
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    private func item(_ account: String) -> [String: Any] {
        identity.merging([kSecAttrAccount as String: account]) { _, new in new }
    }

    func read(_ account: String) -> Data? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { NSLog("Sign-ins: keychain read refused (%d)", status) }
            return nil
        }
        return data
    }

    func write(_ data: Data, as account: String) -> Bool {
        let fields: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(item(account) as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { SecItemDelete(item(account) as CFDictionary) }
        var fresh = item(account)
        fresh[kSecValueData as String] = data
        fresh[kSecAttrLabel as String] = service
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(fresh as CFDictionary, nil)
        if added != errSecSuccess { NSLog("Sign-ins: keychain write failed (%d)", added) }
        return added == errSecSuccess
    }

    func remove(_ account: String) {
        let status = SecItemDelete(item(account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound { NSLog("Sign-ins: keychain remove failed (%d)", status) }
    }

    func accounts() -> [String] {
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

struct FolderShelf: SignInShelf {
    let folder: URL

    private func file(_ account: String) -> URL {
        folder.appendingPathComponent(account + ".json")
    }

    func read(_ account: String) -> Data? {
        try? Data(contentsOf: file(account))
    }

    func write(_ data: Data, as account: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file(account), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func remove(_ account: String) {
        try? FileManager.default.removeItem(at: file(account))
    }

    func accounts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }
    }
}
