import AppKit
import UniformTypeIdentifiers

@MainActor
struct PasswordsExport {
    enum Outcome: Equatable {
        case cancelled
        case failed
        case exported(Int)
    }

    static let menuTitle = "Export Passwords\u{2026}"
    static let title = "Export passwords to a file?"
    static let detail = "The file is not encrypted. Anyone who opens it can read every password. Delete it when you're done."
    static let confirm = "Export\u{2026}"
    static let fileName = "Broadway Passwords.csv"

    var prove: (String, @escaping (Bool) -> Void) -> Void = { reason, done in Vault.prove(reason, done) }
    var ask: (@escaping () -> Void) -> Void = { go in
        Ask.sure(PasswordsExport.title, detail: PasswordsExport.detail, confirm: PasswordsExport.confirm, returnCancels: true, then: go)
    }
    var place: (@escaping (URL?) -> Void) -> Void = { done in PasswordsExport.savePanel(done) }
    var logins: () async -> [Login] = { await Vault.off { Vault.all().compactMap(Vault.login) } }
    var write: (Data, URL) -> Bool = { data, file in PasswordsExport.writeFile(data, to: file) }

    func run(done: @escaping (Outcome) -> Void) {
        prove("export your passwords") { ok in
            guard ok else { return done(.cancelled) }
            ask {
                place { file in
                    guard let file else { return done(.cancelled) }
                    Task { @MainActor in
                        let all = await logins()
                        done(write(Data(Self.csv(all).utf8), file) ? .exported(all.count) : .failed)
                    }
                }
            }
        }
    }

    static func csv(_ logins: [Login]) -> String {
        let sorted = logins.sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
        let rows = sorted.map { login in
            [(login.clear ? "http://" : "https://") + login.host, login.user, login.password, ""].map(quoted).joined(separator: ",")
        }
        return (["url,username,password,note"] + rows).joined(separator: "\n") + "\n"
    }

    static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func savePanel(_ done: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName
        guard let window = Links.window else {
            done(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        panel.beginSheetModal(for: window) { answer in
            done(answer == .OK ? panel.url : nil)
        }
    }

    private static func writeFile(_ data: Data, to file: URL) -> Bool {
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }
}

extension Browser {
    func exportPasswords(_ export: PasswordsExport? = nil) {
        (export ?? PasswordsExport()).run { [weak self] outcome in
            switch outcome {
            case .cancelled: break
            case .failed: self?.announce("The passwords couldn't be written to that file", kind: .error)
            case .exported(let count): self?.announce(count == 1 ? "Exported 1 password" : "Exported \(count) passwords")
            }
        }
    }
}
