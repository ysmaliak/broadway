import CryptoKit
import Foundation
import Security
import os

private let log = Logger(subsystem: "com.ysmaliak.broadway", category: "ConsentMark")

enum ConsentMark {
    static let mark = Data("on".utf8)

    static let signature: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] is String else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return fingerprint(text as String)
    }()

    static func fingerprint(_ requirement: String) -> String {
        SHA256.hash(data: Data(requirement.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func account(_ name: String, signature: String?, world: String?) -> String? {
        guard let signature else { return nil }
        return "\(name) \(signature)" + (world.map { " (\($0))" } ?? "")
    }

    static func granted(_ status: OSStatus, _ data: Data?) -> Bool {
        status == errSecSuccess && data == mark
    }

    static func present(_ name: String, service: String) -> Bool {
        if Store.testing { return true }
        if read(name, service: service) { return true }
        return carryOver(name, service: service)
    }

    @discardableResult
    static func put(_ name: String, service: String) -> Bool {
        if Store.testing { return true }
        guard let account = account(name, signature: signature, world: Store.world) else { return signature == nil }
        if read(name, service: service) { return true }
        var status = quietly { SecItemUpdate(query(account, service: service) as CFDictionary, [kSecValueData as String: mark] as CFDictionary) }
        if status == errSecItemNotFound {
            var item = query(account, service: service)
            item[kSecValueData as String] = mark
            item[kSecAttrLabel as String] = service
            status = SecItemAdd(item as CFDictionary, nil)
        }
        let kept = read(name, service: service)
        if !kept { log.notice("\(name, privacy: .public) left no mark in \(service, privacy: .public) (\(status))") }
        return kept
    }

    static func take(_ name: String, service: String) {
        if Store.testing { return }
        if let account = account(name, signature: signature, world: Store.world) {
            let slot = query(account, service: service) as CFDictionary
            quietly {
                _ = SecItemUpdate(slot, [kSecValueData as String: Data("off".utf8)] as CFDictionary)
                _ = SecItemDelete(slot)
            }
        }
        SecItemDelete(former(name, service: service) as CFDictionary)
    }

    private static func query(_ account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: false,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func former(_ name: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Store.world.map { "\(name) (\($0))" } ?? name]
    }

    private static func read(_ name: String, service: String) -> Bool {
        guard let account = account(name, signature: signature, world: Store.world) else { return false }
        var asked = query(account, service: service)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = quietly { SecItemCopyMatching(asked as CFDictionary, &out) }
        if status != errSecSuccess, status != errSecItemNotFound {
            log.notice("\(name, privacy: .public) in \(service, privacy: .public) can't be read (\(status))")
        }
        return granted(status, out as? Data)
    }

    private static func carryOver(_ name: String, service: String) -> Bool {
        var asked = former(name, service: service)
        asked[kSecReturnAttributes as String] = true
        guard SecItemCopyMatching(asked as CFDictionary, nil) == errSecSuccess, signature != nil else { return false }
        guard put(name, service: service) else { return false }
        SecItemDelete(former(name, service: service) as CFDictionary)
        return true
    }

    private static func quietly<T>(_ body: () -> T) -> T {
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }
}
