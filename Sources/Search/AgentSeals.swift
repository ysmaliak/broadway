import Foundation

@MainActor
enum AgentSeals {
    private(set) static var all: Set<String> = []

    static func keep(_ value: String) {
        guard value.count >= 4 else { return }
        all.insert(value)
    }
}
