import AppKit

@MainActor
final class KitWindowShown {
    var changed: (Bool) -> Void = { _ in }
    private(set) var shown = false
    private weak var window: NSWindow?
    private var watching: [NSObjectProtocol] = []

    func watch(_ window: NSWindow?) {
        guard window !== self.window || watching.isEmpty else { return report() }
        watching.forEach(NotificationCenter.default.removeObserver)
        watching = []
        self.window = window
        if let window {
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification]
            watching = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
        }
        report()
    }

    private func report() {
        let now = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        guard now != shown else { return }
        shown = now
        changed(now)
    }

    isolated deinit {
        watching.forEach(NotificationCenter.default.removeObserver)
    }
}
