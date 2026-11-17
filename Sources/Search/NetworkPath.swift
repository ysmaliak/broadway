import Foundation
import Network

@MainActor
final class NetworkPath {
    static let shared = NetworkPath()

    struct Word: Equatable {
        var changed: Bool
        var returned: Bool
    }

    private(set) var available: Bool?
    private(set) var returns = 0
    private var monitor: NWPathMonitor?
    private var standIn = false
    private var listeners: [UUID: (Bool, Bool) -> Void] = [:]

    nonisolated static func word(before: Bool?, now: Bool) -> Word {
        Word(changed: before != now, returned: before == false && now)
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { NetworkPath.shared.heard(up) } }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    @discardableResult
    func listen(_ listener: @escaping (_ up: Bool, _ returned: Bool) -> Void) -> UUID {
        start()
        let id = UUID()
        listeners[id] = listener
        if let available { listener(available, false) }
        return id
    }

    func stopListening(_ id: UUID?) {
        guard let id else { return }
        listeners[id] = nil
    }

    func heard(_ up: Bool) {
        guard !standIn else { return }
        take(up)
    }

    func said(_ up: Bool) {
        guard Store.testing else { return }
        standIn = true
        take(up)
    }

    private func take(_ up: Bool) {
        let word = Self.word(before: available, now: up)
        available = up
        guard word.changed else { return }
        if word.returned { returns += 1 }
        for listener in Array(listeners.values) { listener(up, word.returned) }
    }
}
