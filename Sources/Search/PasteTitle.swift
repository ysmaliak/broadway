import AppKit

@MainActor
final class PasteTitle {
    static let go = "Paste and Go"
    static let search = "Paste and Search"
    static let shared: PasteTitle = {
        let paste = PasteTitle(board: Store.testing ? nil : MacClipboard())
        paste.primeOnReturn()
        return paste
    }()

    private let board: CopiedBoard?
    private var read: (change: Int, page: URL?, searches: Bool)?
    private var guessed: (change: Int, searches: Bool)?
    private var asking: Int?
    private var waiting: [@MainActor (String) -> Void] = []

    init(board: CopiedBoard?) {
        self.board = board
    }

    static func searches(_ text: String?, page: URL?) -> Bool {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, !looksLikeFile(text) else { return false }
        return Address.url(from: text) == nil && IssueRefs.match(text, page: page) == nil
    }

    private static func looksLikeFile(_ text: String) -> Bool {
        (text.hasPrefix("/") && !text.hasPrefix("//")) || text.hasPrefix("~/")
    }

    static func title(searching: Bool) -> String { searching ? search : go }

    func title(page: URL?, then: @escaping @MainActor (String) -> Void = { _ in }) -> String {
        guard let board else { return Self.go }
        let change = board.change
        if board.free {
            if let read, read.change == change, read.page == page { return Self.title(searching: read.searches) }
            let searches = Self.searches(board.text(), page: page)
            read = (change, page, searches)
            return Self.title(searching: searches)
        }
        if let guessed, guessed.change == change { return Self.title(searching: guessed.searches) }
        guess(board, change: change, then: then)
        return Self.go
    }

    func prime() {
        guard let board, !board.free, guessed?.change != board.change else { return }
        guess(board, change: board.change) { _ in }
    }

    private func primeOnReturn() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prime() }
        }
    }

    private func guess(_ board: CopiedBoard, change: Int, then: @escaping @MainActor (String) -> Void) {
        waiting.append(then)
        guard asking != change else { return }
        asking = change
        Task { [weak self] in
            let link = await board.looksLikeLink()
            guard let self, self.asking == change else { return }
            let searches = !link && board.holdsText
            self.guessed = (change, searches)
            self.asking = nil
            let told = self.waiting
            self.waiting = []
            if searches { told.forEach { $0(Self.search) } }
        }
    }
}
