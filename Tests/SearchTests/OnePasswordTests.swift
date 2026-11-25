import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class OnePasswordTests {
    private var standIn: OnePasswordStandIn!

    init() throws {
        standIn = try OnePasswordStandIn()
        addTeardownBlock { self.standIn.done() }
    }

    @Test func itemsAreReadAsSitesWithTheirNamesAndNoSecrets() throws {
        let rows: [[String: Any]] = [
            ["id": "a1", "category": "LOGIN", "additional_information": "pat@example.com",
             "urls": [["href": "https://www.example.com/login", "primary": true], ["href": "example.com"], ["href": "http://localhost:3000/"]]],
            ["id": "a2", "category": "LOGIN", "additional_information": "work@example.com", "urls": [["href": "https://example.com:8443"]]],
            ["id": "a3", "category": "SECURE_NOTE", "additional_information": "note", "urls": [["href": "https://example.com"]]],
            ["id": "a4", "category": "LOGIN", "urls": [["href": "android://com.vendor.app"]]],
            ["title": "No id", "urls": [["href": "https://example.com"]]],
        ]
        let kept = try #require(OnePassword.items(try JSONSerialization.data(withJSONObject: rows), account: "ACCOUNT1"))

        #expect(kept.count == 3)
        #expect(kept[0].host == "example.com" && kept[0].user == "pat@example.com" && kept[0].port == nil && !kept[0].clear)
        #expect(kept[1].host == "localhost" && kept[1].port == 3000 && kept[1].clear)
        #expect(kept[2].host == "example.com" && kept[2].port == 8443 && kept[2].user == "work@example.com")
        #expect(kept.allSatisfy { $0.item?.account == "ACCOUNT1" })
        #expect(OnePassword.items(Data("<html>".utf8), account: "") == nil)
    }

    @Test func thePasswordIsThePasswordFieldOfTheItem() {
        func data(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        #expect(OnePassword.password(data(["purpose": "PASSWORD", "value": "op-secret-1", "label": "password"])) == "op-secret-1")
        #expect(OnePassword.password(data([["label": "pin", "value": "1234"], ["purpose": "PASSWORD", "label": "Kennwort", "value": "op-secret-2"]])) == "op-secret-2")
        #expect(OnePassword.password(data([["label": "pin", "value": "1234"], ["label": "Password", "value": "op-secret-3"]])) == "op-secret-3")
        #expect(OnePassword.password(data([["label": "pin", "value": "1234"], ["label": "other", "value": "5678"]])) == nil)
        #expect(OnePassword.password(Data("garbage".utf8)) == nil)
        #expect(OnePassword.code(Data("123456\n".utf8)) == "123456")
        #expect(OnePassword.code(Data("[ERROR] nope".utf8)) == nil)
    }

    @Test func aRunReadsALongAnswerWhole() async throws {
        let rows = (0..<3000).map { standIn.login("item\($0)", user: "user\($0)@example.com", password: "unused", href: "https://site\($0).example.com") }
        try standIn.items(rows)

        let run = try #require(await OnePassword.run(["item", "list", "--categories", "Login", "--format", "json"], bound: 10))

        #expect(run.ok)
        #expect(run.out.count > 300_000)
        #expect(OnePassword.items(run.out, account: "")?.count == 3000)
    }

    @Test func aRunPastItsBoundIsStoppedAndSaidToBeLate() async throws {
        standIn.set(mode: "locked")
        let started = Date()

        let run = try #require(await OnePassword.run(["item", "list"], bound: 0.5))

        #expect(run.late)
        #expect(!run.ok)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aChildThatHoldsTheOutputOpenStillEndsTheRun() async throws {
        standIn.set(mode: "holder")
        let started = Date()

        let run = try #require(await OnePassword.run(["item", "list"], bound: 0.5))

        #expect(run.late)
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func aProgramThatCannotStartIsNoAnswerAndNoCrash() async throws {
        let broken = standIn.folder.appendingPathComponent("broken").path
        try "no interpreter line\n".write(toFile: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken)
        OnePassword.standIn = broken

        let run = try #require(await OnePassword.run(["--version"], bound: 2))
        let state = await OnePassword.check()

        #expect(!run.ok)
        #expect(state != .ready(1))
    }

    @Test func theProgramRunsWithACleanEnvironmentAndNoSecretOnItsLine() async throws {
        setenv("OP_SESSION_test", "leaked-token", 1)
        setenv("OP_ACCOUNT", "someone-else", 1)
        defer {
            unsetenv("OP_SESSION_test")
            unsetenv("OP_ACCOUNT")
        }
        try standIn.items([standIn.login("i1", user: "pat@example.com", password: "op-secret-line-1", href: "https://example.com")])

        guard case .found(let kept) = await OnePasswordLookups.shared.lookup(URL(string: "https://example.com/login")!) else {
            Issue.record("nothing found")
            return
        }
        let login = await OnePassword.login(try #require(kept.first))

        #expect(login?.password == "op-secret-line-1")
        #expect(!standIn.calls.joined(separator: "\n").contains("op-secret-line-1"))
        let names = Set(standIn.envs.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) }.filter { $0 != "--" })
        #expect(names.isSubset(of: ["HOME", "USER", "LOGNAME", "PATH", "LANG", "TMPDIR", "PWD", "SHLVL", "_", "OLDPWD"]), "\(names)")
        #expect(!standIn.envs.contains("leaked-token") && !standIn.envs.contains("someone-else"))
        #expect(standIn.calls.contains { $0.hasPrefix("item get i1") && $0.contains("--account ACCOUNT1") && $0.contains("--reveal") })
    }

    @Test func aLookupFindsOnlyThePagesOwnHostAndPort() async throws {
        try standIn.items([
            standIn.login("i1", user: "pat@example.com", password: "p1", href: "https://example.com"),
            standIn.login("i2", user: "dev@example.com", password: "p2", href: "http://localhost:3000"),
            standIn.login("i3", user: "evil@example.com", password: "p3", href: "https://example.com.evil.test"),
            standIn.login("i4", user: "sub@example.com", password: "p4", href: "https://login.example.com"),
        ])

        let here = await OnePasswordLookups.shared.lookup(URL(string: "https://www.example.com/login")!)
        let local = await OnePasswordLookups.shared.lookup(URL(string: "http://localhost:3000/")!)
        let other = await OnePasswordLookups.shared.lookup(URL(string: "http://localhost:3001/")!)

        #expect(here == .found([Kept(host: "example.com", user: "pat@example.com", used: nil, clear: false, port: nil, item: OnePasswordItem(account: "ACCOUNT1", id: "i1"))]))
        #expect((local == .found([Kept(host: "localhost", user: "dev@example.com", used: nil, clear: true, port: 3000, item: OnePasswordItem(account: "ACCOUNT1", id: "i2"))])))
        #expect(other == .found([]))
        #expect(standIn.calls.filter { $0.hasPrefix("item list") }.count == 1)
    }

    @Test func aSlowLookupAnswersLateAndTheNextOneFindsIt() async throws {
        standIn.set(mode: "slow")
        OnePassword.listBound = 0.5
        try standIn.items([standIn.login("i1", user: "pat@example.com", password: "p1", href: "https://example.com")])
        let page = URL(string: "https://example.com/")!

        let first = await OnePasswordLookups.shared.lookup(page)
        try await Task.sleep(for: .seconds(2.5))
        let second = await OnePasswordLookups.shared.lookup(page)

        #expect(first == .late)
        guard case .found(let kept) = second else {
            Issue.record("\(second)")
            return
        }
        #expect(kept.map(\.user) == ["pat@example.com"])
    }

    @Test func troubleIsSaidInPlainWords() async throws {
        let page = URL(string: "https://example.com/")!
        standIn.set(mode: "signedout")
        let signedOut = await OnePasswordLookups.shared.lookup(page)
        OnePasswordLookups.shared.forget()
        standIn.set(mode: "garbage")
        let garbage = await OnePasswordLookups.shared.lookup(page)
        OnePasswordLookups.shared.forget()
        standIn.set(mode: "noaccounts")
        let none = await OnePasswordLookups.shared.lookup(page)
        OnePasswordLookups.shared.forget()
        OnePassword.standIn = standIn.folder.appendingPathComponent("missing").path
        let missing = await OnePasswordLookups.shared.lookup(page)

        #expect(signedOut == .trouble("1Password isn't signed in. Open the 1Password app and unlock it."))
        #expect(garbage == .trouble("1Password gave an answer Broadway couldn't read"))
        #expect(none == .trouble(OnePassword.integration))
        #expect(missing == .trouble(OnePassword.notInstalled))
    }

    @Test func theSetupCheckSaysWhatIsMissing() async throws {
        let ready = await OnePassword.check()
        standIn.set(mode: "noaccounts")
        let none = await OnePassword.check()
        standIn.set(mode: "garbage")
        let garbage = await OnePassword.check()
        standIn.set(mode: "quiet")
        OnePassword.checkBound = 0.5
        let quiet = await OnePassword.check()
        OnePassword.standIn = standIn.folder.appendingPathComponent("missing").path
        let missing = await OnePassword.check()

        #expect(ready == .ready(1))
        #expect(none == .noAccounts)
        #expect(garbage == .trouble("1Password gave an answer Broadway couldn't read"))
        #expect(quiet == .quiet)
        #expect(missing == .missing)
        #expect(OnePasswordSetup.words(.noAccounts) == "Turn on Integrate with 1Password CLI in the 1Password app, in Settings › Developer")
        #expect(OnePasswordSetup.words(.missing) == "The 1Password command line tool isn't on this Mac. Install 1Password CLI from 1Password's website.")
        for state: OnePasswordState? in [nil, .checking, .ready(1), .ready(2), .missing, .noAccounts, .quiet] {
            let words = OnePasswordSetup.words(state)
            let several = words.dropLast().contains(". ")
            #expect(!words.contains(";"))
            #expect(words.hasSuffix(".") == several, "\(words)")
        }
    }

    @Test func aOneTimeCodeComesFromTheItem() async throws {
        _ = standIn.login("i1", user: "pat@example.com", password: "p1", href: "https://example.com", otp: "482913")
        _ = standIn.login("i2", user: "sam@example.com", password: "p2", href: "https://example.com")

        #expect(await OnePassword.oneTimeCode(OnePasswordItem(account: "ACCOUNT1", id: "i1")) == "482913")
        #expect(await OnePassword.oneTimeCode(OnePasswordItem(account: "ACCOUNT1", id: "i2")) == nil)
        #expect(standIn.calls.contains("item get i1 --otp --account ACCOUNT1"))
    }

    @Test func theSwitchIsOffByDefaultAndThePersons() throws {
        let item = try #require(SettingsIndex.item("passwords.onepassword"))

        #expect(item.title == "1Password")
        #expect(item.detail == "Uses the 1Password command line tool")
        #expect(item.group == "passwords")
        #expect(PersonSettings.refusal("passwords.onepassword", value: "true")?.code == "person_only")
        keepSettings("passwords.onepassword")
        Store.settings.removeObject(forKey: "passwords.onepassword")
        #expect(Preferences().onePassword == false)
    }
}
