import Foundation

struct ColumnRest {
    var list: CGFloat = 0
}

@MainActor
final class ColumnMemory {
    enum Part: Hashable { case list }
    private(set) var saved: [UUID: ColumnRest] = [:]
    private(set) var landing = ColumnRest()
    private var current: (space: UUID, ticket: UUID)?
    private var observed: [Part: CGFloat] = [:]
    private struct Port {
        let order: Int
        let read: () -> CGFloat?
    }
    private var readers: [Part: [UUID: Port]] = [:]
    private var order = 0
    private(set) var generation: UUID?

    var restoring: Bool { current != nil }

    func begin(_ space: UUID) -> UUID {
        if let current { finish(current.ticket) }
        landing = saved[space] ?? ColumnRest()
        observed = [:]
        let ticket = UUID()
        current = (space, ticket)
        generation = ticket
        return ticket
    }

    func watch(_ part: Part, id: UUID = UUID(), read: @escaping () -> CGFloat?) {
        var ports = (readers[part] ?? [:]).filter { $0.value.read() != nil }
        order += 1
        ports[id] = Port(order: order, read: read)
        readers[part] = ports
    }

    func offset(_ part: Part) -> CGFloat? {
        (readers[part] ?? [:]).values.sorted { $0.order > $1.order }.lazy.compactMap { $0.read() }.first
    }

    func capture(_ space: UUID) {
        if let value = offset(.list) { note(.list, value: value, in: space) }
    }

    func note(_ part: Part, value: CGFloat, in space: UUID) {
        let value = max(0, value)
        if current?.space == space {
            observed[part] = value
        } else {
            var rest = saved[space] ?? ColumnRest()
            rest.list = value
            saved[space] = rest
        }
    }

    func finish(_ ticket: UUID) {
        guard let current, current.ticket == ticket else { return }
        var rest = saved[current.space] ?? landing
        if let list = observed[.list] { rest.list = list }
        saved[current.space] = rest
        self.current = nil
        observed = [:]
    }
}
