import AppKit

final class ColumnScrollReaderView: NSView {
    weak var memory: ColumnMemory?
    var part = ColumnMemory.Part.list {
        didSet {
            if oldValue != part {
                landed = nil
                destination = nil
            }
        }
    }
    private let port = UUID()
    var destination: (UUID, CGFloat)?
    var viewport: CGFloat?
    var laid: CGFloat?
    private weak var watched: NSScrollView?
    private weak var document: NSView?
    private var observers: [NSObjectProtocol] = []
    private var landed: UUID?
    private var scheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connect()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        connect()
    }

    override func layout() {
        super.layout()
        restore()
    }

    override func viewWillDraw() {
        applyDestination()
        super.viewWillDraw()
    }

    func restore() {
        guard let destination, destination.0 != landed, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.applyDestination()
        }
    }

    private func applyDestination() {
        guard let destination, destination.0 != landed, memory?.generation == destination.0,
              let scroll = enclosingScrollView, scroll.window != nil else { return }
        let clip = scroll.contentView
        let bounds = NSRect(origin: NSPoint(x: clip.bounds.minX, y: destination.1), size: clip.bounds.size)
        guard let document = scroll.documentView, abs(document.frame.height - self.bounds.height) < 1,
              self.bounds.height > 0 else { return }
        if let laid {
            guard abs(self.bounds.height - laid) < 1 else { return }
        }
        if let viewport {
            guard viewport.isFinite, abs(clip.bounds.height - viewport) < 1 else { return }
        }
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
        landed = destination.0
    }

    func connect() {
        restore()
        guard let scroll = enclosingScrollView, scroll.window != nil, let memory else { return }
        if watched !== scroll || document !== scroll.documentView {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            watched = scroll
            document = scroll.documentView
            scroll.contentView.postsFrameChangedNotifications = true
            document?.postsFrameChangedNotifications = true
            observers = [scroll.contentView, document].compactMap { $0 }.map { view in
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restore() }
                }
            }
        }
        let part = part
        memory.watch(part, id: port) { [weak self, weak scroll] in
            guard let self, self.part == part, let scroll, scroll.window != nil,
                  self.enclosingScrollView === scroll else { return nil }
            return scroll.contentView.bounds.minY
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
