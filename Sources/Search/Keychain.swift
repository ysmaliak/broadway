import Foundation
import Security

enum Keychain {
    struct Calls: Sendable {
        var copy: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemCopyMatching($0, $1) }
        var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
        var add: @Sendable (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
        var delete: @Sendable (CFDictionary) -> OSStatus = { SecItemDelete($0) }
    }

    @TaskLocal static var calls = Calls()

    static func read(_ query: [String: Any]) -> (data: Data?, status: OSStatus) {
        var asked = query
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = calls.copy(asked as CFDictionary, &out)
        return (status == errSecSuccess ? out as? Data : nil, status)
    }

    static func list(_ query: [String: Any]) -> (rows: [[String: Any]]?, status: OSStatus) {
        var asked = query
        asked[kSecReturnAttributes as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = calls.copy(asked as CFDictionary, &out)
        return (status == errSecSuccess ? out as? [[String: Any]] : nil, status)
    }

    static func write(_ query: [String: Any], _ fields: [String: Any], orAdd item: [String: Any],
                      quietly: (() -> OSStatus) -> OSStatus = { $0() }) -> (status: OSStatus, added: Bool) {
        let updated = quietly { update(query, fields) }
        guard updated == errSecItemNotFound else { return (updated, false) }
        return (add(item), true)
    }

    static func update(_ query: [String: Any], _ fields: [String: Any]) -> OSStatus {
        calls.update(query as CFDictionary, fields as CFDictionary)
    }

    static func add(_ item: [String: Any]) -> OSStatus {
        calls.add(item as CFDictionary)
    }

    static func delete(_ query: [String: Any]) -> OSStatus {
        calls.delete(query as CFDictionary)
    }
}
