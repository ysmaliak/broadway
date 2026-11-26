import Foundation
import Security
import Testing
@testable import Search

final class KeychainLog: @unchecked Sendable {
    struct Call {
        var kind: String
        var query: [String: Any]
        var fields: [String: Any] = [:]
    }

    private let lock = NSLock()
    private var answers: [String: [OSStatus]]
    private var found: CFTypeRef?
    private(set) var calls: [Call] = []

    init(_ answers: [String: [OSStatus]], found: CFTypeRef? = nil) {
        self.answers = answers
        self.found = found
    }

    var kinds: [String] { lock.withLock { calls.map(\.kind) } }

    private func note(_ kind: String, _ query: CFDictionary, _ fields: CFDictionary? = nil) -> OSStatus {
        lock.withLock {
            calls.append(Call(kind: kind, query: query as? [String: Any] ?? [:], fields: fields as? [String: Any] ?? [:]))
            guard var left = answers[kind], !left.isEmpty else { return errSecSuccess }
            let next = left.removeFirst()
            answers[kind] = left
            return next
        }
    }

    var keychain: Keychain.Calls {
        var made = Keychain.Calls()
        made.copy = { query, out in
            let status = self.note("copy", query)
            if status == errSecSuccess { out?.pointee = self.found }
            return status
        }
        made.update = { query, fields in self.note("update", query, fields) }
        made.add = { item in self.note("add", item) }
        made.delete = { query in self.note("delete", query) }
        return made
    }

    func call(_ index: Int) -> Call { lock.withLock { calls[index] } }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KeychainCallsTests {
    private func same(_ value: Any?, _ wanted: CFString) -> Bool {
        (value as? String) == (wanted as String)
    }

    @Test func aNewPasswordIsUpdatedFirstThenAddedAsAWebFormForThisMacWhenUnlocked() {
        let log = KeychainLog(["update": [errSecItemNotFound]])
        let saved = Keychain.$calls.withValue(log.keychain) {
            Vault.save(host: "example.com", user: "sam", password: "pw-1", port: 8443)
        }
        #expect(saved)
        #expect(log.kinds == ["update", "add"])
        let update = log.call(0), add = log.call(1)
        #expect(same(update.query[kSecClass as String], kSecClassInternetPassword))
        #expect(update.query[kSecAttrServer as String] as? String == "example.com")
        #expect(update.query[kSecAttrAccount as String] as? String == "sam")
        #expect(update.query[kSecAttrPort as String] as? Int == 8443)
        #expect(update.fields[kSecValueData as String] as? Data == Data("pw-1".utf8))
        #expect(same(update.fields[kSecAttrAuthenticationType as String], kSecAttrAuthenticationTypeHTMLForm))
        #expect(same(update.fields[kSecAttrProtocol as String], kSecAttrProtocolHTTPS))
        #expect(same(add.query[kSecAttrAccessible as String], kSecAttrAccessibleWhenUnlocked))
        #expect(add.query[kSecValueData as String] as? Data == Data("pw-1".utf8))
        #expect(add.query[kSecAttrServer as String] as? String == "example.com")
    }

    @Test func aPasswordHeldByTheFormerNameIsDroppedAndAddedAgain() {
        let log = KeychainLog(["update": [errSecItemNotFound], "add": [errSecDuplicateItem, errSecSuccess]])
        let saved = Keychain.$calls.withValue(log.keychain) {
            Vault.save(host: "example.com", user: "sam", password: "pw-2", clear: true)
        }
        #expect(saved)
        #expect(log.kinds == ["update", "add", "delete", "add"])
        #expect(same(log.call(2).query[kSecAttrProtocol as String], kSecAttrProtocolHTTP))
    }

    @Test func aRefusedUpdateOfAPasswordIsNeverAddedBeside() {
        let log = KeychainLog(["update": [errSecAuthFailed]])
        let saved = Keychain.$calls.withValue(log.keychain) {
            Vault.save(host: "example.com", user: "sam", password: "pw-3")
        }
        #expect(!saved)
        #expect(log.kinds == ["update"])
    }

    @Test func aPasswordIsReadAsOneItemsDataAndAListAsAttributesOnly() {
        let log = KeychainLog([:], found: Data("pw-4".utf8) as CFData)
        let login = Keychain.$calls.withValue(log.keychain) {
            Vault.login(Kept(host: "example.com", user: "sam", used: nil, clear: false, port: nil))
        }
        #expect(login?.password == "pw-4")
        let read = log.call(0)
        #expect(read.query[kSecReturnData as String] as? Bool == true)
        #expect(same(read.query[kSecMatchLimit as String], kSecMatchLimitOne))

        let empty = KeychainLog(["copy": [errSecItemNotFound]])
        let all = Keychain.$calls.withValue(empty.keychain) { Vault.all() }
        #expect(all.isEmpty)
        let listed = empty.call(0)
        #expect(listed.query[kSecReturnAttributes as String] as? Bool == true)
        #expect(listed.query[kSecReturnData as String] == nil)
        #expect(same(listed.query[kSecMatchLimit as String], kSecMatchLimitAll))
    }

    @Test func aSignInShelfThatCantUpdateRemovesTheItemAndAddsItForThisDeviceOnly() {
        let log = KeychainLog(["update": [errSecAuthFailed]])
        let shelf = KeychainShelf(service: "Broadway Sign-ins test")
        let written = Keychain.$calls.withValue(log.keychain) { shelf.write(Data("{}".utf8), as: "space-1") }
        #expect(written)
        #expect(log.kinds == ["update", "delete", "add"])
        let add = log.call(2).query
        #expect(add[kSecAttrService as String] as? String == "Broadway Sign-ins test")
        #expect(add[kSecAttrAccount as String] as? String == "space-1")
        #expect(add[kSecAttrLabel as String] as? String == "Broadway Sign-ins test")
        #expect(add[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(same(add[kSecUseAuthenticationUI as String], kSecUseAuthenticationUIFail))
        #expect(same(add[kSecAttrAccessible as String], kSecAttrAccessibleWhenUnlockedThisDeviceOnly))
    }

    @Test func aSignInShelfUpdatesAnItemItAlreadyHas() {
        let log = KeychainLog([:])
        let shelf = KeychainShelf(service: "Broadway Sign-ins test")
        let written = Keychain.$calls.withValue(log.keychain) { shelf.write(Data("{}".utf8), as: "space-1") }
        #expect(written)
        #expect(log.kinds == ["update"])
    }

    @Test func anAutofillItemIsAddedWithItsNoteAndLabelWhenNew() {
        let log = KeychainLog(["update": [errSecItemNotFound]])
        let keeper = KeychainKeeper()
        let written = Keychain.$calls.withValue(log.keychain) {
            keeper.write(.card, id: "one", note: "Visa 4242", data: Data("card".utf8))
        }
        #expect(written)
        #expect(log.kinds == ["update", "add"])
        let add = log.call(1).query
        #expect(same(add[kSecClass as String], kSecClassGenericPassword))
        #expect(add[kSecAttrAccount as String] as? String == "one")
        #expect(add[kSecAttrComment as String] as? String == "Visa 4242")
        #expect(add[kSecAttrLabel as String] as? String == "Broadway autofill")
        #expect(add[kSecMatchSearchList as String] == nil)
        #expect(same(add[kSecAttrAccessible as String], kSecAttrAccessibleWhenUnlocked))
    }

    @Test func aRefusedAutofillUpdateIsNotAdded() {
        let log = KeychainLog(["update": [errSecAuthFailed]])
        let written = Keychain.$calls.withValue(log.keychain) {
            KeychainKeeper().write(.card, id: "one", note: "", data: Data("card".utf8))
        }
        #expect(!written)
        #expect(log.kinds == ["update"])
    }

    @Test func theOpenRouterKeyIsAddedOnlyWhenNoneIsKept() {
        let fresh = KeychainLog(["update": [errSecItemNotFound]])
        #expect(Keychain.$calls.withValue(fresh.keychain) { OpenRouterKeychain().write("sk-or-test-1") })
        #expect(fresh.kinds == ["update", "add"])
        let add = fresh.call(1).query
        #expect(add[kSecAttrService as String] as? String == OpenRouterKeychain.service)
        #expect(add[kSecAttrLabel as String] as? String == OpenRouterKeychain.service)
        #expect(add[kSecValueData as String] as? Data == Data("sk-or-test-1".utf8))
        #expect(same(add[kSecAttrAccessible as String], kSecAttrAccessibleWhenUnlocked))

        let refused = KeychainLog(["update": [errSecAuthFailed]])
        #expect(!Keychain.$calls.withValue(refused.keychain) { OpenRouterKeychain().write("sk-or-test-2") })
        #expect(refused.kinds == ["update"])

        let kept = KeychainLog([:], found: Data("sk-or-test-3".utf8) as CFData)
        #expect(Keychain.$calls.withValue(kept.keychain) { OpenRouterKeychain().read() } == "sk-or-test-3")
        #expect(same(kept.call(0).query[kSecMatchLimit as String], kSecMatchLimitOne))
    }
}
