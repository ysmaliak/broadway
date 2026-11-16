import Combine
import QuartzCore

@MainActor
final class TitleTrace {
    static var all: [UUID: TitleTrace] = [:]

    let born = CACurrentMediaTime()
    private(set) var seen: [(at: Double, label: String)] = []
    private var watch: AnyCancellable?

    static func follow(_ tab: Tab) {
        let trace = TitleTrace()
        all[tab.id] = trace
        trace.watch = kitObserve(initial: false, distinct: true, { [weak tab] in tab?.label ?? "" }) { [weak trace] label in
            trace?.note(label)
        }
    }

    private func note(_ label: String) {
        guard seen.last?.label != label else { return }
        seen.append((CACurrentMediaTime() - born, label))
    }

    var report: [[Any]] { seen.map { [($0.at * 1000).rounded(), $0.label] } }
}
