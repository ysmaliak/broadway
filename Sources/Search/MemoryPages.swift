import AppKit
import WebKit

@MainActor
enum MemoryPages {
    private static let homes = NSHashTable<Browser>.weakObjects()

    static func note(_ browser: Browser) {
        homes.add(browser)
    }

    static func start() {
        MemoryWatch.shared.renew = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { renew() }
            }
        }
        MemoryWatch.shared.start()
    }

    static var browsers: [Browser] {
        var seen: [Browser] = []
        for browser in Browsers.all + AgentBoard.browsers + homes.allObjects where !seen.contains(where: { $0 === browser }) {
            seen.append(browser)
        }
        return seen
    }

    static func renew() {
        var list: [Int32: [UUID]] = [:]
        for browser in browsers {
            for tab in browser.tabs + browser.parkedTabs {
                guard let built = tab.built else { continue }
                let pid = Int32(built.processID)
                guard pid > 0 else { continue }
                list[pid, default: []].append(tab.id)
            }
        }
        MemoryWatch.shared.pages(list)
    }
}

extension Tab {
    var memoryStopped: Bool {
        failure == MemoryWords.title || MemoryWatch.shared.holds(id)
    }

    var agentEnds: Int { stuck.restarts + memoryEnds }

    func takeOwedFailure() -> ToolOutcome? {
        if memoryOwed {
            memoryOwed = false
            return .failure(MemoryWords.agent, code: .pageTooLarge, retrySafe: false)
        }
        return takeStuckFailure()
    }

    func stopForMemory() -> Bool {
        guard MemoryWatch.shared.take(id) != nil else { return false }
        stuck.letGo()
        stuckEnd = nil
        _ = retry.tryAgain()
        failure = MemoryWords.title
        if agent {
            memoryOwed = true
            memoryEnds += 1
        }
        return true
    }
}
