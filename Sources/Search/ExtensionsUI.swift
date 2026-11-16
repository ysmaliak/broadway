import AppKit
import Combine
import WebKit

@MainActor
enum ExtensionsLogic {
    static let privateNote = "Each extension stays out of private windows until you allow it in its … menu. One you allow can tell which windows are private, but may still keep what you visit in them."
    static let recorderNote = "Can record your screen, and macOS asks what to share each time"

    static func line(_ symbol: String, _ title: String, _ detail: String, button: KitBroadwayButton) -> KitFormLine {
        let line = KitFormLine(title, detail: detail, callout: true, leading: KitForm.symbol(symbol), controls: [button])
        line.firstLine = 6
        return line
    }

    static func store(_ browser: Browser) -> KitFormLine {
        line("bag", "Add from the Chrome Web Store", "Or find it in the store and press Add to Broadway on its page",
             button: KitBroadwayButton("Open the Store") { browser.open(Browser.webStore, foreground: true) })
    }

    static func bringOver(_ browser: Browser) -> KitFormLine {
        line("square.and.arrow.down.on.square", "From another browser",
             "Your extensions from Chrome, Arc or Brave, installed fresh from the store. You say yes to each.",
             button: KitBroadwayButton("Bring Them Over") {
                 browser.bringingExtensions = true
                 browser.lead(to: InternalPage(.importing))
             })
    }

    static func unpacked(_ extensions: Extensions) -> KitFormLine {
        line("folder", "Load an unpacked extension", "A folder with a manifest.json, yours or exported. Reload picks up your changes.",
             button: KitBroadwayButton("Choose…") { extensions.installFolder() })
    }

    static func recorder(_ id: String) -> KitFormLine {
        let name = Browser.extensionName(id)
        let remove = KitBroadwayButton("Remove…")
        remove.action = { [weak remove] in SettingsQuestion.recorder(name).ask(over: remove?.window) { ExtensionCapture.forget(id) } }
        let line = KitFormLine(name, detail: recorderNote, controls: [remove])
        line.firstLine = 6
        return line
    }

    static func folder(_ item: Installed) -> String {
        item.source.map { "From “\(URL(fileURLWithPath: $0).lastPathComponent)”" } ?? "From a folder"
    }

    static func detail(_ item: Installed, _ context: WKWebExtensionContext?, _ extensions: Extensions) -> String {
        var parts = ["Version \(item.version)", item.fromStore ? "Chrome Web Store" : folder(item)]
        if item.enabled, context == nil { parts.append("couldn't start") }
        if extensions.newTabPageID == item.id { parts.append("shows in new tabs") }
        if context?.hasAccessToPrivateData == true { parts.append("allowed in private windows") }
        if let errors = context.map(Extensions.errors(of:)), !errors.isEmpty { parts.append("\(errors.count) warning\(errors.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    static func actions(_ item: Installed, _ context: WKWebExtensionContext?, _ extensions: Extensions, over window: NSWindow? = nil) -> [KitMenuItem] {
        var items: [KitMenuItem] = [
            .action(item.pinned == true ? "Unpin" : "Pin to Toolbar") { extensions.setPinned(item.id, !(item.pinned ?? false)) },
        ]
        if context?.overrideNewTabPageURL != nil {
            let on = extensions.newTabPageID == item.id
            items.append(.action(on ? "Stop Showing in New Tabs" : "Show in New Tabs") { extensions.setNewTabPage(on ? nil : item.id) })
        }
        if context?.optionsPageURL != nil {
            items.append(.action("Options") { extensions.openOptions(item.id) })
        }
        if item.source != nil || !item.fromStore {
            items.append(.action("Reload") { extensions.reload(item.id) })
        }
        if let context {
            items.append(.separator)
            if (context.webExtension.manifest["incognito"] as? String) == "not_allowed" {
                items.append(.action("Private Windows Aren't Supported", enabled: false) {})
            } else {
                let on = context.hasAccessToPrivateData
                items.append(.action("Allow in Private Windows", on: on, id: "allow-private-\(item.id)") {
                    extensions.setPrivate(item.id, !on)
                })
            }
        }
        items.append(.separator)
        items.append(.action("Remove…") {
            SettingsQuestion.extension(item.name, fromStore: item.fromStore).ask(over: window) { extensions.remove(item.id) }
        })
        return items
    }
}

final class ExtensionLinkRow: NSView, KitFits {
    let extensions: Extensions
    let field = KitField(placeholder: "Paste a link to an extension, or its id", label: "Link or id")
    private let add = KitBroadwayButton("Add", kind: .primary)
    private let spinner = NSProgressIndicator()
    private var watch: AnyCancellable?

    init(extensions: Extensions) {
        self.extensions = extensions
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [field, add, spinner] as [NSView] { addSubview(view) }
        field.onChange = { [weak self] _ in self?.refresh() }
        field.onSubmit = { [weak self] in self?.submit() }
        add.action = { [weak self] in self?.submit() }
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func kitHeight(width: CGFloat) -> CGFloat { KitField.height(small: false) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: KitField.height(small: false)) }

    func refresh() {
        let busy = extensions.busy != nil
        add.isHidden = busy
        add.isEnabled = Crx.id(in: field.text) != nil
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    func submit() {
        guard Crx.id(in: field.text) != nil else { return }
        extensions.install(from: field.text)
        field.text = ""
        refresh()
    }

    override func layout() {
        super.layout()
        let trailing: NSSize = add.isHidden ? NSSize(width: 16, height: 16) : add.intrinsicContentSize
        let x = bounds.width - trailing.width
        add.frame = kitSnap(NSRect(x: x, y: (bounds.height - trailing.height) / 2, width: trailing.width, height: trailing.height))
        spinner.frame = kitSnap(NSRect(x: bounds.width - 16, y: (bounds.height - 16) / 2, width: 16, height: 16))
        field.frame = NSRect(x: 0, y: 0, width: max(0, x - 8), height: bounds.height)
    }
}

final class ExtensionRowView: NSView, KitFits {
    let extensions: Extensions
    private(set) var item: Installed
    private let icon = NSImageView()
    private let glyph = KitSymbol("puzzlepiece.extension", style: .init(size: 13), tint: .secondaryLabelColor)
    private let line: KitFormLine
    private let more = KitButton(.plain(press: 1), label: "")
    private let toggle: KitSwitch
    private var watch: AnyCancellable?

    init(item: Installed, extensions: Extensions) {
        self.item = item
        self.extensions = extensions
        toggle = KitControls.toggle(id: "extension-\(item.id)", label: item.name, isOn: item.enabled, system: true) { on in
            extensions.setEnabled(item.id, on)
        }
        line = KitFormLine(item.name, detail: " ", controls: [])
        super.init(frame: .zero)
        more.content = KitSymbol("ellipsis.circle", style: .init(size: 13), tint: .secondaryLabelColor)
        more.action = { [weak self] in self?.popMore() }
        line.controls = [more, toggle]
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, glyph, line] as [NSView] { addSubview(view) }
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(_ item: Installed) {
        self.item = item
        refresh()
    }

    private var context: WKWebExtensionContext? { extensions.contexts[item.id] }

    func refresh() {
        let context = context
        let image = context?.webExtension.icon(for: CGSize(width: 32, height: 32))
        icon.image = image
        icon.isHidden = image == nil
        glyph.isHidden = image != nil
        line.setText(item.name, detail: ExtensionsLogic.detail(item, context, extensions))
        line.detailLabel.toolTip = item.source
        toggle.set(item.enabled, animated: true)
        toggle.setAccessibilityLabel(item.name)
        more.setAccessibilityLabel("More for \(item.name)")
        more.toolTip = "More for \(item.name)"
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func kitHeight(width: CGFloat) -> CGFloat { max(22, line.kitHeight(width: width - 34)) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width > 0 ? bounds.width : 560))
    }

    override func layout() {
        super.layout()
        let box = kitSnap(NSRect(x: 0, y: (bounds.height - 22) / 2, width: 22, height: 22))
        icon.frame = box
        glyph.frame = box
        line.frame = NSRect(x: 34, y: 0, width: bounds.width - 34, height: bounds.height)
    }

    private func popMore() { KitMenu.pop(ExtensionsLogic.actions(item, context, extensions, over: window), below: more) }

    override func menu(for event: NSEvent) -> NSMenu? { KitMenu.make(ExtensionsLogic.actions(item, context, extensions, over: window)) }
}

final class StoreOfferView: NSView {
    var busy: Bool { didSet { if busy != oldValue { refresh() } } }
    var onAdd: (() -> Void)?

    private let glass = KitGlass()
    private let symbol = KitSymbol("puzzlepiece.extension", style: .init(size: 11, weight: .medium), tint: KitForm.wash(light: 0.4, dark: 0.35))
    private let words = KitLabel("", font: .systemFont(ofSize: 13), color: NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    })
    private let add = KitButton(.keycap(.primary), label: "Add")
    private let ring = RingView()

    init(busy: Bool, add: (() -> Void)? = nil) {
        self.busy = busy
        onAdd = add
        super.init(frame: .zero)
        glass.capsule = true
        glass.tintColor = Palette.NS.glassTint
        self.add.content = KitLabel("Add", font: .systemFont(ofSize: 12, weight: .semibold), color: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
        })
        self.add.padding = 9
        self.add.height = 22
        self.add.action = { [weak self] in self?.onAdd?() }
        for view in [glass, symbol, words, self.add, ring] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        words.text = busy ? "Adding…" : "Add this extension to Broadway"
        add.isHidden = busy
        ring.isHidden = !busy
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var trailing: NSSize { busy ? NSSize(width: 10, height: 10) : add.intrinsicContentSize }

    override var intrinsicContentSize: NSSize {
        let words = words.intrinsicContentSize
        let symbol = symbol.intrinsicContentSize
        let height = max(words.height, symbol.height, trailing.height)
        return NSSize(width: 16 + symbol.width + 12 + words.width + 12 + trailing.width + 10, height: height + 18)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let mid = bounds.height / 2
        var x: CGFloat = 16
        let symbolSize = symbol.intrinsicContentSize
        symbol.frame = kitSnap(NSRect(x: x, y: mid - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height))
        x += symbolSize.width + 12
        let wordsSize = words.intrinsicContentSize
        words.frame = kitSnap(NSRect(x: x, y: mid - wordsSize.height / 2, width: wordsSize.width, height: wordsSize.height))
        x += wordsSize.width + 12
        let size = trailing
        let box = kitSnap(NSRect(x: x, y: mid - size.height / 2, width: size.width, height: size.height))
        add.frame = box
        ring.frame = box
    }
}

@MainActor
enum StoreOfferRules {
    static func isStorePage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return false }
        let host = url.host()?.lowercased() ?? ""
        return host == "chromewebstore.google.com"
            || (host == "chrome.google.com" && url.path.hasPrefix("/webstore"))
    }

    static func offered(_ tab: Tab?, _ extensions: Extensions) -> String? {
        guard let tab, let url = tab.address, let id = Crx.storeID(of: url),
              tab.storePlaced != id, !extensions.installed.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
