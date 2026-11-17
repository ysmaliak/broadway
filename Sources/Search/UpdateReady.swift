import AppKit
import Observation

struct StagedUpdate: Equatable {
    let version: String
    let build: String
}

@MainActor
@Observable
final class UpdateWait {
    private(set) var staged: StagedUpdate?
    private(set) var hidden: StagedUpdate?
    private(set) var arrivals = 0
    @ObservationIgnored private(set) var install: (() -> Void)?

    var card: Bool { staged != nil && staged != hidden }

    func stage(_ update: StagedUpdate, install: @escaping () -> Void) {
        self.install = install
        guard staged != update else { return }
        staged = update
        if card { arrivals += 1 }
    }

    func hide() {
        hidden = staged
    }

    func clear() {
        staged = nil
        hidden = nil
        install = nil
    }
}

@MainActor
struct RestartLoss: Equatable {
    var privateWindows = 0
    var downloads = 0
    var live = 0
    var typed = false

    var nothing: Bool { privateWindows == 0 && downloads == 0 && live == 0 && !typed }

    static let title = "Restart to update?"

    var sentence: String? {
        var parts: [String] = []
        if privateWindows > 0 { parts.append(privateWindows == 1 ? "closes your private window" : "closes your private windows") }
        if downloads > 0 { parts.append(downloads == 1 ? "stops a download" : "stops \(downloads) downloads") }
        if live > 0 { parts.append(live == 1 ? "ends a call or recording" : "ends \(live) calls or recordings") }
        if typed { parts.append("loses what you typed on a page and haven't sent") }
        guard let last = parts.popLast() else { return nil }
        let list = parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
        return "Restarting now \(list)"
    }

    static func counted(_ entries: [FetchEntry]) -> Int {
        entries.filter { [.downloading, .pausing, .resuming].contains($0.state) || $0.state == .paused && $0.resumeData != nil }.count
    }

    static func gather(browsers: [Browser], fetches: Fetches, wait: TimeInterval = 1, then done: @escaping (RestartLoss) -> Void) {
        var found = RestartLoss()
        found.privateWindows = browsers.filter { $0.isPrivate }.count
        found.downloads = counted(fetches.entries)
        let tabs = browsers.flatMap { $0.tabs + $0.parkedTabs }
        found.live = tabs.filter { $0.built.map { ExtensionCapture.capturing($0) } == true }.count
        let asked = browsers.filter { !$0.isPrivate }.flatMap { $0.tabs + $0.parkedTabs }.filter { $0.built != nil }
        guard !asked.isEmpty else { return done(found) }
        var left = asked.count
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            done(found)
        }
        for tab in asked {
            tab.unsaved { typed in
                if typed { found.typed = true }
                left -= 1
                if left == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { MainActor.assumeIsolated { finish() } }
    }
}

@MainActor
enum UpdateRestart {
    static var gather: (@escaping (RestartLoss) -> Void) -> Void = { done in
        RestartLoss.gather(browsers: Browsers.all, fetches: Shared.fetches, then: done)
    }

    private static var asking = false

    static func ask(_ wait: UpdateWait, over window: NSWindow?) {
        guard let install = wait.install, !asking else { return }
        asking = true
        gather { loss in
            asking = false
            guard let sentence = loss.sentence else { return install() }
            Ask.sure(RestartLoss.title, detail: sentence, confirm: "Restart", cancel: "Not Now", returnCancels: true,
                     over: window ?? Browsers.front?.window) {
                if loss.typed { LeaveQuit.settle() }
                install()
            }
        }
    }
}
