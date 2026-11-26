import Foundation
import AppKit
import Observation

// What you have kept. Downloads work already; this is only the memory of them,
// so a file you fetched an hour ago is one click from the Finder rather than a
// hunt through a folder.

struct Keep: Codable, Identifiable, Equatable {
    var name: String
    var from: String
    var path: String
    var date: Date

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
    var stillThere: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
@Observable
final class Loot {
    private(set) var kept: [Keep] = []
    private(set) var clearedAt: Date

    static let recentRoom = 6

    private let file: URL

    init(file: URL = Store.file("downloads.json")) {
        self.file = file
        clearedAt = Store.settings.object(forKey: "downloads.cleared") as? Date ?? .distantPast
        load()
        if Store.settings.object(forKey: "downloads.cleared") == nil, let newest = kept.first {
            clearedAt = newest.date
        }
    }

    var recent: [Keep] {
        Array(kept.filter { $0.date > clearedAt }.prefix(Self.recentRoom))
    }

    func clearRecent(at date: Date = Date()) {
        clearedAt = date
        Store.settings.set(date, forKey: "downloads.cleared")
    }

    func add(_ keep: Keep) {
        kept.removeAll { $0.path == keep.path }
        kept.insert(keep, at: 0)
        if kept.count > 500 { kept.removeLast(kept.count - 500) }
        save()
    }

    func restore(_ keep: Keep) {
        kept.removeAll { $0.path == keep.path }
        let at = kept.firstIndex { $0.date <= keep.date } ?? kept.endIndex
        kept.insert(keep, at: at)
        save()
    }

    func forget(_ keep: Keep) {
        kept.removeAll { $0.id == keep.id }
        save()
    }

    /// Only the list is emptied. Files you asked for are yours, and deleting
    /// them is the Finder's business, not a browser's.
    func forgetAll() {
        kept = []
        save()
    }

    static var benchAsked: [String] = []

    func reveal(_ keep: Keep) {
        if Store.testing {
            Self.benchAsked.append("reveal " + keep.name)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([keep.url])
    }

    func open(_ keep: Keep) {
        if Store.testing {
            Self.benchAsked.append("open " + keep.name)
            return
        }
        NSWorkspace.shared.open(keep.url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Keep].self, from: data) else {
            Store.quarantine(file)
            return
        }
        kept = list
    }

    private func save() {
        let snapshot = kept
        // One after another, the newest last (see Disk).
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}
