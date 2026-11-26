import AppKit
import Combine
import Observation
import Quartz
import UniformTypeIdentifiers
import WebKit

struct FileChoiceRules {
    let accept: String
    let multiple: Bool
    let directories: Bool

    var types: [UTType] {
        accept.split(separator: ",").compactMap { part in
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if token.hasPrefix(".") { return UTType(filenameExtension: String(token.dropFirst())) }
            switch token {
            case "image/*": return .image
            case "audio/*": return .audio
            case "video/*": return .movie
            default: return UTType(mimeType: token)
            }
        }
    }

    func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentTypeKey]) else { return false }
        if values.isDirectory == true { return directories }
        guard values.isRegularFile == true, !directories else { return false }
        let tokens = accept.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !tokens.isEmpty else { return true }
        let known = types
        if tokens.contains(where: { $0.hasPrefix(".") && url.lastPathComponent.lowercased().hasSuffix($0) }) { return true }
        if let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
           known.contains(where: { type.conforms(to: $0) }) { return true }
        return known.isEmpty && !tokens.contains(where: { $0.hasPrefix(".") })
    }

    func validated(_ urls: [URL]) -> [URL]? {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !unique.isEmpty, multiple || unique.count == 1, unique.allSatisfy(accepts) else { return nil }
        return unique
    }

    func recent(downloads: [Keep], uploads: [Upload], privateDownloads: [Keep], isPrivate: Bool) -> [FileItem] {
        var seen = Set<String>()
        return FileItem.merged(downloads: isPrivate ? privateDownloads : downloads, uploads: isPrivate ? [] : uploads)
            .filter { item in
                let url = URL(fileURLWithPath: item.path)
                return accepts(url) && seen.insert(url.standardizedFileURL.path).inserted
            }
    }
}

@MainActor
final class FileChoiceReply {
    private var completion: (([URL]?) -> Void)?
    private(set) var finished = false

    init(_ completion: @escaping ([URL]?) -> Void) { self.completion = completion }

    func finish(_ urls: [URL]?) {
        guard !finished else { return }
        finished = true
        let completion = completion
        self.completion = nil
        completion?(urls)
    }

    deinit { completion?(nil) }
}

@MainActor
@Observable
final class FileChoice: NSObject, NSOpenSavePanelDelegate, NSWindowDelegate {
    static var probing: Bool { Store.testing && Store.settings.bool(forKey: "filebox.probe") }
    @ObservationIgnored let tabID: Tab.ID
    @ObservationIgnored let host: String
    @ObservationIgnored let reply: FileChoiceReply
    private(set) var rules: FileChoiceRules
    private(set) var items: [FileItem] = []
    private(set) var selected = Set<Int>()
    private(set) var cursor = 0
    private(set) var trouble = ""
    var ready: Bool { panel != nil || finderRequested }
    var keepsVisibleWhenInactive: Bool { panel?.hidesOnDeactivate == false }
    @ObservationIgnored private(set) var finderRequested = false
    @ObservationIgnored private(set) var previewing = false
    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var panel: ChoicePanel?
    @ObservationIgnored private var finder: NSOpenPanel?
    @ObservationIgnored private var quickLook: ChoicePanel?
    @ObservationIgnored private var snapshotWindow: NSWindow?
    @ObservationIgnored private var snapshotParking: [(NSWindow, NSRect)] = []
    @ObservationIgnored private var snapshotPages = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var anchor = 0
    @ObservationIgnored private var previewURL: URL?

    init(browser: Browser, tab: Tab, webView: WKWebView, host: String, rules: FileChoiceRules, reply: FileChoiceReply) {
        self.browser = browser
        self.tabID = tab.id
        self.webView = webView
        self.host = host
        self.rules = rules
        self.reply = reply
        super.init()
    }

    func activeMoved(to id: Tab.ID?) {
        if id != tabID { cancel() }
    }

    func setAccept(_ accept: String) {
        rules = FileChoiceRules(accept: accept, multiple: rules.multiple, directories: rules.directories)
    }

    func showInFinder() {
        show(at: nil, finderOnly: true)
    }

    func show(at rect: NSRect?, finderOnly: Bool = false) {
        guard !reply.finished, let browser else { return }
        guard browser.activeID == tabID || browser.peekTab?.id == tabID else { return cancel() }
        items = rules.recent(downloads: browser.loot.kept, uploads: Uploads.shared.kept,
                             privateDownloads: browser.privateFileDownloads, isPrivate: webView.flatMap { browser.anyTab(for: $0) }?.shy == true || webView?.configuration.websiteDataStore.isPersistent == false)
        selected = items.isEmpty ? [] : [0]
        if finderOnly || rules.directories { return chooseInFinder() }
        let hosting = FileChoiceCardView(choice: self, ground: false)
        let size = hosting.intrinsicContentSize
        let panel = ChoicePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = host.isEmpty ? "Choose a file for this page" : "Choose a file for \(host)"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = hosting
        panel.hidesOnDeactivate = false
        self.panel = panel
        if let window = webView?.window ?? browser.window, let webView {
            let page = window.convertToScreen(webView.convert(webView.bounds, to: nil))
            let spot = rect.map { window.convertToScreen(webView.convert($0, to: nil)) }
            var origin = NSPoint(x: spot?.minX ?? page.midX - size.width / 2, y: (spot?.minY ?? page.maxY - 70) - size.height - 6)
            origin.x = min(max(origin.x, page.minX + 8), max(page.minX + 8, page.maxX - size.width - 8))
            origin.y = max(page.minY + 8, min(origin.y, page.maxY - size.height - 8))
            panel.setFrameOrigin(origin)
            if !Store.testing {
                window.addChildWindow(panel, ordered: .above)
                panel.makeKeyAndOrderFront(nil)
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } })
        }
        if !Store.testing {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.window === self.panel || event.window === self.quickLook {
                    return self.key(event.keyCode, modifiers: event.modifierFlags) ? nil : event
                }
                if event.type != .keyDown, event.window !== self.panel, event.window !== self.quickLook { self.cancel() }
                return event
            }
        }
    }

    func select(_ index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard items.indices.contains(index), !reply.finished else { return }
        cursor = index
        if rules.multiple && modifiers.contains(.shift) {
            selected.formUnion(min(anchor, index)...max(anchor, index))
        } else if rules.multiple && modifiers.contains(.command) {
            if !selected.insert(index).inserted { selected.remove(index) }
            anchor = index
        } else {
            selected = [index]
            anchor = index
        }
        if previewing { preview() }
    }

    @discardableResult
    func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        switch code {
        case 53: cancel()
        case 36, 76:
            if cursor == items.count { chooseInFinder() } else { pick() }
        case 49: previewing ? closePreview() : preview()
        case 125, 126:
            cursor = min(items.count, max(0, cursor + (code == 125 ? 1 : -1)))
            if cursor < items.count { select(cursor, modifiers: modifiers) }
        default: return false
        }
        return true
    }

    func pick() {
        guard !selected.isEmpty else { return }
        submit(selected.sorted().compactMap { items.indices.contains($0) ? URL(fileURLWithPath: items[$0].path) : nil })
    }

    @discardableResult
    func submit(_ urls: [URL]) -> Bool {
        guard !reply.finished, let valid = rules.validated(urls) else {
            trouble = "Choose \(rules.multiple ? "files" : "one file") that \(rules.multiple ? "match" : "matches") this field and can still be read"
            return false
        }
        if webView?.configuration.websiteDataStore.isPersistent == true, webView.flatMap({ browser?.anyTab(for: $0) })?.shy != true {
            Uploads.shared.add(valid, to: host)
        }
        finish(valid)
        return true
    }

    @discardableResult
    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, rules.multiple || providers.count == 1 else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSURL.self) { value, _ in
                        continuation.resume(returning: value as? URL)
                    }
                }
                guard let url else { return }
                urls.append(url)
            }
            submit(urls)
        }
        return true
    }

    func cancel() { finish(nil) }

    private func finish(_ urls: [URL]?) {
        guard !reply.finished, !ending else { return }
        ending = true
        endSnapshot()
        closePreview()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        finder?.cancel(nil)
        finder = nil
        hidePanel()
        reply.finish(urls)
        if browser?.fileChoice === self { browser?.fileChoice = nil }
    }

    private func hidePanel() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }

    func chooseInFinder() {
        guard !reply.finished, !finderRequested else { return }
        finderRequested = true
        closePreview()
        hidePanel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if Store.testing { return }
        guard let window = webView?.window ?? browser?.window else { return cancel() }
        let panel = NSOpenPanel()
        finder = panel
        panel.delegate = self
        panel.canChooseFiles = !rules.directories
        panel.canChooseDirectories = rules.directories
        panel.allowsMultipleSelection = rules.multiple
        panel.resolvesAliases = true
        if !rules.types.isEmpty { panel.allowedContentTypes = rules.types }
        panel.message = host.isEmpty ? "Choose a file for this page" : "Choose a file for \(host)"
        panel.beginSheetModal(for: window) { [weak self, weak panel] answer in
            guard let self, !self.reply.finished, !self.ending else { return }
            self.finder = nil
            if answer == .OK, let urls = panel?.urls { if !self.submit(urls) { self.cancel() } }
            else { self.cancel() }
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return rules.accepts(url)
    }

    func preview() {
        guard items.indices.contains(cursor) else { return }
        previewURL = URL(fileURLWithPath: items[cursor].path)
        guard let previewURL, rules.accepts(previewURL) else { return }
        previewing = true
        if Store.testing { return }
        if let view = quickLook?.contentView as? QLPreviewView {
            quickLook?.title = items[cursor].name
            view.previewItem = previewURL as NSURL
            return
        }
        guard let panel, let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 480, height: 420), style: .normal) else { return }
        let preview = ChoicePanel(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        preview.title = items[cursor].name
        preview.isReleasedWhenClosed = false
        preview.hidesOnDeactivate = true
        preview.delegate = self
        preview.contentView = view
        view.autoresizingMask = [.width, .height]
        view.previewItem = previewURL as NSURL
        var origin = NSPoint(x: panel.frame.maxX + 12, y: panel.frame.maxY - preview.frame.height)
        if let screen = panel.screen?.visibleFrame {
            origin.x = min(max(screen.minX + 8, origin.x), screen.maxX - preview.frame.width - 8)
            origin.y = min(max(screen.minY + 8, origin.y), screen.maxY - preview.frame.height - 8)
        }
        preview.setFrameOrigin(origin)
        panel.addChildWindow(preview, ordered: .above)
        quickLook = preview
        preview.orderFront(nil)
    }

    private func closePreview() {
        if let preview = quickLook {
            (preview.contentView as? QLPreviewView)?.close()
            preview.parent?.removeChildWindow(preview)
            preview.orderOut(nil)
            preview.contentView = nil
        }
        quickLook = nil
        previewing = false
        previewURL = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === quickLook else { return true }
        closePreview()
        return false
    }

    func beginSnapshot() -> [String: Any]? {
        guard Store.testing, NSApp.isHidden, panel != nil else { return nil }
        let view = FileChoiceCardView(choice: self, ground: true)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSApp.effectiveAppearance
        window.title = "Broadway file choice probe"
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = view
        snapshotParking = NSApp.windows.filter { $0 !== window }.map { ($0, $0.frame) }
        let away = NSPoint(x: (NSScreen.screens.map { $0.frame.maxX }.max() ?? 0) + 10000,
                           y: (NSScreen.screens.map { $0.frame.maxY }.max() ?? 0) + 10000)
        for (other, _) in snapshotParking {
            other.orderOut(nil)
            other.setFrameOrigin(away)
        }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        window.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.minY + 20))
        snapshotPages = Bench.pagesShown
        snapshotWindow = window
        Bench.pagesShown = true
        window.orderBack(nil)
        NSApp.unhideWithoutActivation()
        view.layoutSubtreeIfNeeded()
        return ["window": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier,
                "width": Int(window.frame.width * 2), "height": Int(window.frame.height * 2)]
    }

    func endSnapshot() {
        guard let window = snapshotWindow else { return }
        window.orderOut(nil)
        NSApp.hide(nil)
        window.contentView = nil
        window.close()
        snapshotWindow = nil
        for (other, frame) in snapshotParking { other.setFrame(frame, display: false) }
        snapshotParking = []
        Bench.pagesShown = snapshotPages
    }

    final class ChoicePanel: KitLitPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

@MainActor
final class FileChoiceCardView: NSView {
    static let width: CGFloat = 420

    private unowned let choice: FileChoice
    private let glass = KitGlass.floating(radius: MenuMetrics.corner, ground: false)
    private let inside = KitBox(fill: nil)
    private let header = KitLabel("", font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
    private let empty = KitLabel("No recent files match this field", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let list = KitBox(fill: nil)
    private let trouble = KitLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let hint = KitLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let cancel: KitGlassKey
    private let choose: KitGlassKey
    private let finder: FileChoiceFinderRow
    private var rows: [FileChoiceRow] = []
    private var shownItems: [FileItem] = []
    private var shownCursor = -1

    init(choice: FileChoice, ground: Bool) {
        self.choice = choice
        cancel = KitGlassKey(title: "Cancel", tall: 26) { [weak choice] in choice?.cancel() }
        choose = KitGlassKey(title: "Choose", tall: 26) { [weak choice] in choice?.pick() }
        finder = FileChoiceFinderRow { [weak choice] in choice?.chooseInFinder() }
        super.init(frame: .zero)
        if ground {
            let back = KitBox(fill: .windowBackgroundColor)
            back.autoresizingMask = [.width, .height]
            addSubview(back)
        }
        addSubview(glass)
        glass.hold(inside)
        header.text = choice.host.isEmpty ? "Choose a file for this page" : "Choose a file for \(choice.host)"
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = list
        list.addSubview(finder)
        for view in [header, empty, scroll, trouble, hint, cancel, choose] as [NSView] { inside.addSubview(view) }
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var scrollHeight: CGFloat { CGFloat(min(choice.items.count, 6)) * 52 + 48 }

    private func place(apply: Bool) -> CGFloat {
        let inner = Self.width - 8
        var y: CGFloat = 4 + 8
        let headerHeight = header.intrinsicContentSize.height
        if apply { header.frame = kitSnap(NSRect(x: 4 + 10, y: y, width: inner - 20, height: headerHeight)) }
        y += headerHeight + 6
        empty.isHidden = !choice.items.isEmpty
        if !empty.isHidden {
            let height = empty.intrinsicContentSize.height
            if apply { empty.frame = kitSnap(NSRect(x: 4 + 10, y: y + 10, width: inner - 20, height: height)) }
            y += height + 20 + 6
        }
        if apply { scroll.frame = NSRect(x: 4, y: y, width: inner, height: scrollHeight) }
        y += scrollHeight + 6
        trouble.isHidden = choice.trouble.isEmpty
        if !trouble.isHidden {
            let height = trouble.intrinsicContentSize.height
            if apply { trouble.frame = kitSnap(NSRect(x: 4 + 10, y: y, width: inner - 20, height: height)) }
            y += height + 6
        }
        let keyHeight: CGFloat = 26
        if apply {
            let hintSize = hint.intrinsicContentSize
            hint.frame = kitSnap(NSRect(x: 4 + 10, y: y + (keyHeight - hintSize.height) / 2, width: hintSize.width, height: hintSize.height))
            let right = 4 + inner - 10
            let chooseSize = choose.intrinsicContentSize
            choose.frame = NSRect(x: right - chooseSize.width, y: y, width: chooseSize.width, height: keyHeight)
            let cancelSize = cancel.intrinsicContentSize
            cancel.frame = NSRect(x: choose.frame.minX - 8 - cancelSize.width, y: y, width: cancelSize.width, height: keyHeight)
        }
        return y + keyHeight + 8 + 4
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width + 16, height: place(apply: false) + 16) }

    override func layout() {
        super.layout()
        let items = choice.items
        let selected = choice.selected
        let cursor = choice.cursor
        hint.text = choice.rules.multiple ? "⌘ / ⇧ select · Space preview" : "Space preview"
        trouble.text = choice.trouble
        choose.isEnabled = !selected.isEmpty
        if items != shownItems {
            shownItems = items
            rows.forEach { $0.removeFromSuperview() }
            rows = items.enumerated().map { index, item in
                FileChoiceRow(item: item) { [weak choice] in
                    choice?.select(index, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                    if NSApp.currentEvent?.clickCount == 2 { choice?.pick() }
                }
            }
            rows.forEach(list.addSubview)
            invalidateIntrinsicContentSize()
        }
        for (index, row) in rows.enumerated() {
            row.picked = selected.contains(index)
            row.lit = selected.contains(index) || cursor == index
            row.faint = !selected.isEmpty && !selected.contains(index)
        }
        finder.lit = cursor == items.count
        glass.frame = NSRect(x: 8, y: 8, width: Self.width, height: bounds.height - 16)
        inside.frame = glass.bounds
        _ = place(apply: true)
        let inner = Self.width - 8
        var y: CGFloat = 4
        for row in rows {
            row.frame = NSRect(x: 4, y: y, width: inner - 8, height: 50)
            y += 52
        }
        finder.frame = NSRect(x: 4, y: y, width: inner - 8, height: 40)
        y += 40 + 4
        list.frame = NSRect(x: 0, y: 0, width: inner, height: max(y, scroll.contentSize.height))
        if cursor != shownCursor {
            let first = shownCursor < 0
            shownCursor = cursor
            let target = cursor < rows.count ? rows[cursor].frame : finder.frame
            reveal(target, animated: !first)
        }
    }

    private func reveal(_ rect: NSRect, animated: Bool) {
        let clip = scroll.contentView
        let visible = clip.bounds
        var origin = visible.origin
        if rect.minY < visible.minY { origin.y = rect.minY } else if rect.maxY > visible.maxY { origin.y = rect.maxY - visible.height }
        guard origin != visible.origin else { return }
        if animated, !Motion.reduced {
            NSAnimationContext.kit(Motion.kitQuick) {
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scroll.reflectScrolledClipView(clip)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return choice.drop(urls.compactMap { NSItemProvider(contentsOf: $0) })
    }
}

@MainActor
private final class FileChoiceSlab: NSView {
    var faint = false { didSet { if faint != oldValue { alphaValue = faint ? 0.5 : 1; shade() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        shade()
    }

    override func layout() {
        super.layout()
        shade()
    }

    private func shade() {
        guard let layer else { return }
        let shape = bounds.insetBy(dx: 0, dy: 1)
        layer.shadowPath = CGPath(roundedRect: shape, cornerWidth: 12, cornerHeight: 12, transform: nil)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = faint ? 0 : kitDark ? 0.24 : 0.11
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = kitDark
        let shape = bounds.insetBy(dx: 0, dy: 1)
        let path = NSBezierPath(roundedRect: shape, xRadius: 12, yRadius: 12)
        let fill = dark ? [NSColor(white: 1, alpha: 0.19), NSColor(white: 1, alpha: 0.13)] : [NSColor(white: 1, alpha: 0.92), NSColor(white: 1, alpha: 0.7)]
        NSGradient(colors: fill)?.draw(in: path, angle: -90)
        let edge = NSBezierPath(roundedRect: shape.insetBy(dx: 0.375, dy: 0.375), xRadius: 11.625, yRadius: 11.625)
        edge.lineWidth = 0.75
        let stroke = dark ? [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.06)] : [NSColor(white: 0, alpha: 0.05), NSColor(white: 0, alpha: 0.13)]
        NSGraphicsContext.saveGraphicsState()
        let outline = edge.cgPath.copy(strokingWithWidth: 0.75, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        NSBezierPath(cgPath: outline).addClip()
        NSGradient(colors: stroke)?.draw(in: shape, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class FileChoiceRow: NSView {
    private let slab = FileChoiceSlab()
    private let icon = NSImageView()
    private let name: KitLabel
    private let detail: KitLabel
    private let check = KitSymbol("checkmark", style: KitSymbol.Style(size: 12, weight: .semibold))
    private let tap: () -> Void
    private let said: String
    var lit = false { didSet { slab.isHidden = !lit } }
    var faint = false { didSet { slab.faint = faint } }
    var picked = false {
        didSet {
            check.isHidden = !picked
            setAccessibilitySelected(picked)
        }
    }

    init(item: FileItem, tap: @escaping () -> Void) {
        self.tap = tap
        let size = (try? URL(fileURLWithPath: item.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let source = item.source.isEmpty ? "This Mac" : (item.kind == .downloaded ? "From " : "Given to ") + item.source
        said = bytes + " · " + source
        name = KitLabel(item.name, font: .systemFont(ofSize: 15))
        name.overflow = .middle
        detail = KitLabel(said, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        super.init(frame: .zero)
        icon.image = NSWorkspace.shared.icon(forFile: item.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        slab.isHidden = true
        check.isHidden = true
        for view in [slab, icon, name, detail, check] as [NSView] { addSubview(view) }
        name.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name + ", " + said)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { tap() }
    }

    override func accessibilityPerformPress() -> Bool {
        tap()
        return true
    }

    override func layout() {
        super.layout()
        slab.frame = bounds
        icon.frame = NSRect(x: 10, y: (bounds.height - 24) / 2, width: 24, height: 24)
        let checkSize = check.intrinsicContentSize
        check.frame = kitSnap(NSRect(x: bounds.width - 10 - checkSize.width, y: (bounds.height - checkSize.height) / 2, width: checkSize.width, height: checkSize.height))
        let right = (picked ? check.frame.minX - 12 : bounds.width - 10) - 4
        let nameHeight = name.intrinsicContentSize.height
        let detailHeight = detail.intrinsicContentSize.height
        let top = (bounds.height - nameHeight - 3 - detailHeight) / 2
        let width = max(0, right - 46)
        name.frame = kitSnap(NSRect(x: 46, y: top, width: min(width, name.intrinsicContentSize.width), height: nameHeight))
        detail.frame = kitSnap(NSRect(x: 46, y: top + nameHeight + 3, width: min(width, detail.intrinsicContentSize.width), height: detailHeight))
    }
}

@MainActor
private final class FileChoiceFinderRow: NSView {
    private let slab = FileChoiceSlab()
    private let folder = KitSymbol("folder", style: KitSymbol.Style(size: 13))
    private let words = KitLabel("Choose in Finder…", font: .systemFont(ofSize: 15))
    private let key = KitLabel("↩", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    private let tap: () -> Void
    var lit = false { didSet { slab.isHidden = !lit } }

    init(tap: @escaping () -> Void) {
        self.tap = tap
        super.init(frame: .zero)
        slab.isHidden = true
        for view in [slab, folder, words, key] as [NSView] { addSubview(view) }
        words.setAccessibilityElement(false)
        key.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Choose in Finder…")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { tap() }
    }

    override func accessibilityPerformPress() -> Bool {
        tap()
        return true
    }

    override func layout() {
        super.layout()
        slab.frame = bounds
        let folderSize = folder.intrinsicContentSize
        folder.frame = kitSnap(NSRect(x: 10 + (24 - folderSize.width) / 2, y: (bounds.height - folderSize.height) / 2, width: folderSize.width, height: folderSize.height))
        let wordsSize = words.intrinsicContentSize
        words.frame = kitSnap(NSRect(x: 46, y: (bounds.height - wordsSize.height) / 2, width: wordsSize.width, height: wordsSize.height))
        let keySize = key.intrinsicContentSize
        key.frame = kitSnap(NSRect(x: bounds.width - 10 - keySize.width, y: (bounds.height - keySize.height) / 2, width: keySize.width, height: keySize.height))
    }
}

@MainActor
enum FileInputCapture {
    static let script = WKUserScript(source: """
    (() => {
      let last = null;
      document.addEventListener('click', event => {
        const input = event.composedPath().find(e => e instanceof HTMLInputElement && e.type === 'file');
        if (input) last = { input, at: performance.now() };
      }, true);
      window.__broadwayFileInput = () => {
        const active = document.activeElement;
        const input = last && performance.now() - last.at < 2000 ? last.input : active;
        last = null;
        if (!(input instanceof HTMLInputElement) || input.type !== 'file') return null;
        const r = input.getBoundingClientRect();
        return { accept: input.accept, x: r.x, y: r.y, width: r.width, height: r.height };
      };
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
}
