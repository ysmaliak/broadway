import Foundation

struct LiveReadTicket: Equatable {
    var space: UUID
    var source: LiveSource
    var paused: Int
    var applied: Int

    func holds(_ current: LiveReadTicket, paused now: Bool) -> Bool {
        !now && self == current
    }
}

@MainActor
final class LiveShared {
    private var running: [String: Task<LiveReader.Answer, Never>] = [:]
    private(set) var asked = 0

    func forget() { running = [:] }

    static func key(_ folder: LiveFolder) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let source = (try? encoder.encode(folder.source)).map { String(decoding: $0, as: UTF8.self) } ?? folder.source.address
        return "\(folder.space.uuidString) \(source)"
    }

    func answer(_ folder: LiveFolder, reader: @escaping @MainActor (LiveFolder) async -> LiveReader.Answer) async -> LiveReader.Answer {
        let key = Self.key(folder)
        if let task = running[key] { return await task.value }
        asked += 1
        let task = Task { @MainActor in await reader(folder) }
        running[key] = task
        let answer = await task.value
        if running[key] == task { running[key] = nil }
        return answer
    }
}
