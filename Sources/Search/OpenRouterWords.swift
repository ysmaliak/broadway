import Foundation

enum AIGroupWords {
    static let needs = "Needs Apple Intelligence on this Mac or an OpenRouter key"
    static let keyTitle = "OpenRouter key"
    static let keyPrompt = "Paste your key"
    static let keysPage = URL(string: "https://openrouter.ai/settings/keys")!
    static let checking = "Checking the key with OpenRouter"

    static func line(mac: Bool, key: Bool) -> String {
        if key { return "Related tabs find each other as you open them. OpenRouter sorts and names them with your key." }
        guard mac else { return needs }
        return "Related tabs find each other as you open them. Runs on this Mac. Nothing leaves it."
    }

    static let sent = "Tab titles, site names, folder names and searches go to OpenRouter, never addresses, authors or pages"
    static let offer = "Add your own key and OpenRouter sorts and names folders. The key stays in this Mac's Keychain."

    static func keyLine(state: OpenRouterKey.State, trouble: String?) -> String {
        if state == .checking { return checking }
        if let trouble { return trouble }
        return state == .saved ? sent : offer
    }

    static let stepTitle = "Add an OpenRouter key?"

    static func stepLine(mac: Bool) -> String {
        if !mac {
            return "A key is what turns on folders on this Mac. Only tab titles, site names, folder names and searches go to OpenRouter. It costs a fraction of a cent a folder on your account, and the key stays in this Mac's Keychain."
        }
        return "OpenRouter sorts and names your folders. Only tab titles, site names, folder names and searches are sent. It costs a fraction of a cent a folder on your account, and the key stays in this Mac's Keychain."
    }

    static let getKey = "Get a Key"
    static let saved = "Key saved"
}
