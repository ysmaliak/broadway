import Foundation

final class AgentClock: @unchecked Sendable {
    @TaskLocal static var current: AgentClock?

    private var marks: [[Any]] = []

    static func mark(_ name: @autoclosure () -> String) {
        current?.add(name())
    }

    func add(_ name: String) {
        marks.append([name, Date().timeIntervalSince1970 * 1000])
    }

    var list: [[Any]] { marks }

    static func asked(_ request: [String: Any]) -> AgentClock? {
        request["timing"] as? Bool == true ? AgentClock() : nil
    }
}
