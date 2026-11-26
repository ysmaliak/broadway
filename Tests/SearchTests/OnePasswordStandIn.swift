import Foundation
@testable import Search

@MainActor
final class OnePasswordStandIn {
    let folder: URL
    var program: String { folder.appendingPathComponent("op").path }

    static let script = """
    #!/bin/sh
    here=$(dirname "$0")
    mode=$(cat "$here/mode" 2>/dev/null)
    printf '%s\\n' "$*" >> "$here/calls"
    env >> "$here/envs"
    echo "--" >> "$here/envs"
    case "$1 $2" in
      "--version ")
        [ "$mode" = "quiet" ] && exec sleep 30
        echo "2.42.0"; exit 0;;
      "account list")
        [ "$mode" = "quiet" ] && exec sleep 30
        [ "$mode" = "noaccounts" ] && { echo "[]"; exit 0; }
        [ "$mode" = "garbage" ] && { echo "<html>not json"; exit 0; }
        cat "$here/accounts.json"; exit 0;;
      "item list")
        case "$mode" in
          slow) sleep 2;;
          locked) exec sleep 30;;
          holder) sleep 10;;
          garbage) echo "<html>not json"; exit 0;;
          signedout) echo "[ERROR] 2026/11/24 18:00:00 You are not currently signed in. Please run op signin --help for instructions" >&2; exit 1;;
        esac
        cat "$here/items.json"; exit 0;;
      "item get")
        id=$3
        [ "$mode" = "signedout" ] && { echo "[ERROR] 2026/11/24 18:00:00 You are not currently signed in. Please run op signin --help for instructions" >&2; exit 1; }
        case " $* " in
          *" --otp "*) [ -f "$here/otp-$id" ] && { cat "$here/otp-$id"; exit 0; }
            echo "[ERROR] 2026/11/24 18:00:00 item has no one-time password" >&2; exit 1;;
        esac
        [ -f "$here/item-$id.json" ] && { cat "$here/item-$id.json"; exit 0; }
        echo "[ERROR] 2026/11/24 18:00:00 isn't an item" >&2; exit 1;;
    esac
    echo "[ERROR] unknown command" >&2
    exit 1
    """

    init(mode: String = "") throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("op-stand-in-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.script.write(toFile: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program)
        try #"[{"url":"my.1password.com","email":"pat@example.com","user_uuid":"USER1","account_uuid":"ACCOUNT1"}]"#
            .write(to: folder.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        try "[]".write(to: folder.appendingPathComponent("items.json"), atomically: true, encoding: .utf8)
        set(mode: mode)
        OnePassword.standIn = program
        OnePassword.listBound = 5
        OnePassword.askBound = 10
        OnePassword.checkBound = 5
        OnePasswordLookups.shared.forget()
    }

    func set(mode: String) {
        try? mode.write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    func items(_ rows: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: rows)
        try data.write(to: folder.appendingPathComponent("items.json"))
    }

    func login(_ id: String, user: String, password: String, href: String, otp: String? = nil) -> [String: Any] {
        let fields: [[String: Any]] = [["id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": password,
                                        "reference": "op://Private/\(id)/password"]]
        try? JSONSerialization.data(withJSONObject: fields).write(to: folder.appendingPathComponent("item-\(id).json"))
        if let otp { try? otp.write(to: folder.appendingPathComponent("otp-\(id)"), atomically: true, encoding: .utf8) }
        return ["id": id, "title": "Login \(id)", "category": "LOGIN", "additional_information": user,
                "vault": ["id": "VAULT1", "name": "Private"], "urls": [["label": "website", "primary": true, "href": href]]]
    }

    var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var envs: String { (try? String(contentsOf: folder.appendingPathComponent("envs"), encoding: .utf8)) ?? "" }

    func done() {
        OnePassword.standIn = nil
        OnePassword.listBound = 5
        OnePassword.askBound = 60
        OnePassword.checkBound = 5
        OnePasswordLookups.shared.forget()
        try? FileManager.default.removeItem(at: folder)
    }
}
