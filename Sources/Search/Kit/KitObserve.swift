import Combine
import Foundation
import Observation

@MainActor
final class KitObserver<Value> {
    private let read: @MainActor () -> Value
    private let changed: @MainActor (Value) -> Void
    private let same: ((Value, Value) -> Bool)?
    private var last: Value?
    nonisolated(unsafe) private var live = true
    private var armed = false

    init(read: @escaping @MainActor () -> Value, same: ((Value, Value) -> Bool)?, changed: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.changed = changed
        self.same = same
    }

    func start(initial: Bool) {
        let value = arm()
        last = value
        if initial { changed(value) }
    }

    nonisolated func cancel() { live = false }

    private func arm() -> Value {
        armed = true
        return withObservationTracking { read() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fire() } }
        }
    }

    private func fire() {
        guard live, armed else { return }
        armed = false
        let value = arm()
        if let same, let last, same(last, value) { return }
        last = value
        changed(value)
    }
}

@MainActor
func kitObserve<Value>(initial: Bool = true, _ read: @escaping @MainActor () -> Value,
                       changed: @escaping @MainActor (Value) -> Void) -> AnyCancellable {
    let observer = KitObserver(read: read, same: nil, changed: changed)
    observer.start(initial: initial)
    return AnyCancellable { observer.cancel() }
}

@MainActor
func kitObserve<Value: Equatable>(initial: Bool = true, distinct: Bool, _ read: @escaping @MainActor () -> Value,
                                  changed: @escaping @MainActor (Value) -> Void) -> AnyCancellable {
    let observer = KitObserver(read: read, same: distinct ? { $0 == $1 } : nil, changed: changed)
    observer.start(initial: initial)
    return AnyCancellable { observer.cancel() }
}

@MainActor
final class KitReads {
    var changed: (@MainActor () -> Void)?
    private let now: Bool
    private var ticket = 0
    nonisolated(unsafe) private var live = true

    init(now: Bool = false, _ changed: (@MainActor () -> Void)? = nil) {
        self.now = now
        self.changed = changed
    }

    @discardableResult
    func track<T>(_ work: () -> T) -> T {
        ticket &+= 1
        let mine = ticket
        if now {
            return withObservationTracking(work) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.live, self.ticket == mine else { return }
                    self.changed?()
                }
            }
        }
        return withObservationTracking(work) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.live, self.ticket == mine else { return }
                    self.changed?()
                }
            }
        }
    }

    nonisolated func stop() { live = false }
}

@MainActor
func kitTrack(_ work: @escaping @MainActor () -> Void) -> AnyCancellable {
    let reads = KitReads()
    reads.changed = { [weak reads] in reads?.track(work) }
    reads.track(work)
    return AnyCancellable { reads.stop() }
}
