import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PasswordsExportTests {
    private var steps: [String] = []
    private var written: [(Data, URL)] = []
    private let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unused.csv")
    private let logins = [
        Login(host: "shop.example", user: "ada", password: "p,a\"ss\nword"),
        Login(host: "old.example", user: "", password: "plain", clear: true),
    ]

    private func export(proof: Bool = true, agrees: Bool = true, file: URL?, kept: Int? = nil) -> PasswordsExport {
        var made = PasswordsExport()
        made.prove = { [unowned self] _, done in steps.append("prove"); done(proof) }
        made.ask = { [unowned self] go in steps.append("ask"); if agrees { go() } }
        made.place = { [unowned self] done in steps.append("place"); done(file) }
        made.logins = { [unowned self] in steps.append("read"); return (logins, kept ?? logins.count) }
        made.write = { [unowned self] data, url in steps.append("write"); written.append((data, url)); return true }
        return made
    }

    private func run(_ export: PasswordsExport) async -> PasswordsExport.Outcome? {
        var outcome: PasswordsExport.Outcome?
        export.run { outcome = $0 }
        for _ in 0..<20 where outcome == nil { await Task.yield() }
        return outcome
    }

    @Test func nothingIsWrittenWhenTheMacPasswordIsNotGiven() async {
        let export = export(proof: false, file: target)

        let outcome = await run(export)

        #expect(outcome == .cancelled)
        #expect(steps == ["prove"])
        #expect(written.isEmpty)
    }

    @Test func nothingIsWrittenWhenTheWarningIsCancelled() async {
        let export = export(agrees: false, file: target)

        _ = await run(export)

        #expect(steps == ["prove", "ask"])
        #expect(written.isEmpty)
    }

    @Test func nothingIsWrittenWhenTheSavePanelIsCancelled() async {
        let export = export(file: nil)

        let outcome = await run(export)

        #expect(outcome == .cancelled)
        #expect(steps == ["prove", "ask", "place"])
        #expect(written.isEmpty)
    }

    @Test func thePasswordsAreReadOnlyAfterProofWarningAndPlace() async {
        let export = export(file: target)

        let outcome = await run(export)

        #expect(outcome == .exported(2, of: 2))
        #expect(steps == ["prove", "ask", "place", "read", "write"])
        #expect(written.first?.1 == target)
    }

    @Test func passwordsTheKeychainWouldNotHandOverAreCountedAndNamed() async {
        let export = export(file: target, kept: 22)

        let outcome = await run(export)

        #expect(outcome == .exported(2, of: 22))
        #expect(PasswordsExport.words(380, of: 400) == "Exported 380 of 400 passwords. 20 couldn't be read from the keychain.")
        #expect(PasswordsExport.words(400, of: 400) == "Exported 400 passwords")
        #expect(PasswordsExport.words(1, of: 1) == "Exported 1 password")
    }

    @Test func theFileHasTheColumnsChromeAnd1PasswordReadWithOneRowPerPassword() {
        let text = PasswordsExport.csv(logins)

        let rows = Vault.parse(csv: text)

        #expect(rows.first == ["url", "username", "password", "note"])
        #expect(rows.count == 3)
        #expect(rows.dropFirst().map { $0.count } == [4, 4])
    }

    @Test func awkwardPasswordsComeBackExactlyThroughTheImporter() {
        let text = PasswordsExport.csv(logins)

        let rows = Vault.parse(csv: text).dropFirst()

        #expect(rows.map { $0[0] } == ["http://old.example", "https://shop.example"])
        #expect(rows.map { $0[1] } == ["", "ada"])
        #expect(rows.map { $0[2] } == ["plain", "p,a\"ss\nword"])
        #expect(rows.map { Vault.host(of: $0[0]) } == ["old.example", "shop.example"])
    }

    @Test func theRealWriterLeavesAFileOnlyThePersonCanRead() async throws {
        let folder = Store.folder.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(PasswordsExport.fileName)
        var export = export(file: file)
        export.write = PasswordsExport().write

        let outcome = await run(export)

        #expect(outcome == .exported(2, of: 2))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("url,username,password,note\n"))
    }

    @Test func theFileIsOnlyThePersonsFromTheMomentItIsMadeAndReplacesAReadableOne() throws {
        let folder = Store.folder.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(PasswordsExport.fileName)
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(PasswordsExport.writeFile(Data("url,username,password,note\n".utf8), to: file))

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "url,username,password,note\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [PasswordsExport.fileName])
    }

    @Test func theWordsAreTheOnesAskedFor() {
        #expect(PasswordsExport.menuTitle == "Export Passwords…")
        #expect(PasswordsExport.title == "Export passwords to a file?")
        #expect(PasswordsExport.detail == "The file is not encrypted. Anyone who opens it can read every password. Delete it when you're done.")
        #expect(PasswordsExport.confirm == "Export…")
        #expect(PasswordsExport.fileName == "Broadway Passwords.csv")
    }

    @Test func thePasswordsPageMenuOffersTheExport() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.stage(saved: [Kept(host: "shop.example", user: "ada")])

        let menu = KitMenu.make(PasswordsBody(browser: browser).moreItems())

        #expect(menu.items.map(\.title) == ["Export Passwords…"])
        #expect(menu.items.first?.isEnabled == true)
    }

    @Test func noCommandOrAgentCanStartAnExport() {
        let commands = Command.all.map { "\($0.id) \($0.title)".lowercased() }
        let verbs = PersonCommands.names.map { $0.lowercased() }

        let exporting = (commands + verbs).filter { $0.contains("export") && ($0.contains("password") || $0.contains("login")) }

        #expect(exporting.isEmpty)
    }
}
