import Foundation

@MainActor
enum AgentSignInBox {
    static var hosts: [UUID: String] = [:]

    static func note(_ tab: UUID) -> String? {
        guard let host = hosts[tab] else { return nil }
        return "\(host) asks for a name and a password in a sign-in box of its own before it shows the page. Broadway doesn't fill that box. broadway handoff \"Sign in\" lets the person do it."
    }
}
