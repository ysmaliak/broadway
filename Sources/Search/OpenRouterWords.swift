import Foundation

enum AIGroupWords {
    static let needs = "Needs Apple Intelligence on this Mac or an OpenRouter key"
    static let keyTitle = "OpenRouter key"
    static let keyPrompt = "Paste your key"
    static let keysPage = URL(string: "https://openrouter.ai/settings/keys")!
    static let checking = "Checking the key with OpenRouter"

    static func line(mac: Bool, key: Bool, remoteDecides: Bool) -> String {
        if key, remoteDecides { return "Related tabs find each other as you open them. OpenRouter sorts and names them with your key." }
        guard mac else { return needs }
        if key { return "Related tabs find each other on this Mac as you open them. OpenRouter names the folders with your key." }
        return "Related tabs find each other as you open them. Runs on this Mac. Nothing leaves it."
    }

    static func sent(remoteDecides: Bool) -> String {
        remoteDecides
            ? "Tab titles, site names, folder names and searches go to OpenRouter, never addresses, authors or pages"
            : "A folder's tab titles, site names and search go to OpenRouter, never addresses, authors or pages"
    }

    static func offer(remoteDecides: Bool) -> String {
        remoteDecides
            ? "Add your own key and OpenRouter sorts and names folders. The key stays in this Mac's Keychain."
            : "Add your own key and OpenRouter names folders. The key stays in this Mac's Keychain."
    }

    static func keyLine(state: OpenRouterKey.State, trouble: String?, remoteDecides: Bool) -> String {
        if state == .checking { return checking }
        if let trouble { return trouble }
        return state == .saved ? sent(remoteDecides: remoteDecides) : offer(remoteDecides: remoteDecides)
    }

    static let stepTitle = "Add an OpenRouter key?"

    static func stepLine(mac: Bool, remoteDecides: Bool) -> String {
        if remoteDecides, !mac {
            return "A key is what turns on folders on this Mac. Only tab titles, site names and searches go to OpenRouter. It costs a fraction of a cent a folder on your account, and the key stays in this Mac's Keychain."
        }
        if remoteDecides {
            return "OpenRouter sorts and names your folders. Only tab titles, site names and searches are sent. It costs a fraction of a cent a folder on your account, and the key stays in this Mac's Keychain."
        }
        return "OpenRouter names your folders. Only tab titles, site names and searches are sent. It costs a fraction of a cent a folder on your account, and the key stays in this Mac's Keychain."
    }

    static let getKey = "Get a Key"
    static let saved = "Key saved"
}
