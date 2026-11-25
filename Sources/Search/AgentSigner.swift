import Darwin
import Foundation
import Security

struct AgentCodeFacts: Equatable {
    var executable: String
    var valid: Bool
    var apple: Bool
    var team: String?
    var signer: String?
}

enum AgentSigner: Equatable {
    case developer(String)
    case apple
    case unsigned
    case interpreter
    case elsewhere
    case claims(String, signer: String?)

    static let vendors: [(word: String, name: String, team: String)] = [
        ("claude", "Claude Code", "Q6L2SF6YDW"), ("codex", "Codex", "2DC432GLL2"),
        ("opencode", "opencode", "5NZ4Q7NXJ4"), ("cursor", "Cursor", "VDXQ22DGB9"),
    ]

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "ruby", "perl", "php", "java", "osascript", "pwsh", "lua"]

    static func interpreter(_ executable: String) -> Bool {
        let base = (executable as NSString).lastPathComponent.lowercased()
        let stem = String(base.reversed().drop { $0.isNumber || $0 == "." }.reversed())
        return interpreters.contains(stem)
    }

    static func vendor(_ told: String?) -> (name: String, team: String)? {
        let base = ((told ?? "") as NSString).lastPathComponent.lowercased()
        return vendors.first { base == $0.word || base.hasPrefix($0.word + "-") || base.hasPrefix($0.word + " ") }.map { ($0.name, $0.team) }
    }

    static func judge(_ facts: AgentCodeFacts, told: String?) -> AgentSigner {
        if interpreter(facts.executable) { return .interpreter }
        let signer: String? = !facts.valid ? nil : facts.apple ? "Apple" : facts.team == nil ? nil : facts.signer
        if let vendor = vendor(told), facts.team != vendor.team || !facts.valid { return .claims(vendor.name, signer: signer) }
        if facts.valid, facts.apple { return .apple }
        if let signer { return .developer(signer) }
        return .unsigned
    }

    func line(name: String) -> String? {
        switch self {
        case .developer(let signer): return "\(name), signed by \(signer)"
        case .apple: return "\(name), signed by Apple"
        case .unsigned: return "\(name), not signed"
        case .interpreter: return nil
        case .elsewhere: return "From another machine over ssh"
        case .claims(let claimed, let signer): return "Calls itself \(claimed), " + (signer.map { "signed by \($0)" } ?? "not signed")
        }
    }

    var detail: String? {
        switch self {
        case .developer(let signer): return "Signed by \(signer)"
        case .apple: return "Signed by Apple"
        case .unsigned: return "Not signed"
        case .interpreter: return nil
        case .elsewhere: return "From another machine over ssh"
        case .claims: return line(name: "")
        }
    }

    static func organisation(_ subject: String) -> String? {
        var name = subject
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) { name = String(name[..<open.lowerBound]) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func read(pid: Int32, started: Int64) -> AgentCodeFacts? {
        guard pid > 1, AgentProcess.startTime(pid) == started, let token = token(pid) else { return nil }
        var code: SecCode?
        let audit = withUnsafeBytes(of: token) { Data($0) }
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &code) == errSecSuccess, let code else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let executable = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? (String(cString: path) as NSString).lastPathComponent : ""
        let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        let apple = valid && requirement.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } == true
        var team: String?
        var signer: String?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let found = info as? [String: Any] {
            team = found[kSecCodeInfoTeamIdentifier as String] as? String
            if let leaf = (found[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
               let subject = SecCertificateCopySubjectSummary(leaf) as String? {
                signer = organisation(subject)
            }
        }
        guard AgentProcess.startTime(pid) == started else { return nil }
        return AgentCodeFacts(executable: executable, valid: valid, apple: apple, team: team, signer: signer)
    }

    private static func token(_ pid: Int32) -> audit_token_t? {
        var task: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let done = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        guard done == KERN_SUCCESS, token.val.5 == UInt32(bitPattern: pid) else { return nil }
        return token
    }
}
