import AppKit
import ObjectiveC

@_silgen_name("swift_demangle")
private func layoutWatchDemangle(_ name: UnsafePointer<CChar>?, _ length: UInt, _ buffer: UnsafeMutablePointer<CChar>?,
                                 _ size: UnsafeMutablePointer<UInt>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

@MainActor
enum LayoutWatch {
    nonisolated static let alarm = 3
    nonisolated static let late = 12
    nonisolated static let kept = 40
    nonisolated static let assertKey = "NSWindowAssertWhenDisplayCycleLimitReached"

    struct Report {
        let window: String
        let views: Int
        let from: Int
        var passes: Int
        var dirty: [[String]]
        var asked: [String]
        var written = false
        var looped = false

        var text: String {
            var lines = ["LayoutLoop: \(window), \(views) views, \(passes) layout passes in one display cycle\(passes > views ? ", AppKit's limit" : "")"]
            for (index, names) in dirty.enumerated() {
                lines.append("  dirty at pass \(from + index): " + (names.isEmpty ? "none" : names.joined(separator: "; ")))
            }
            for line in asked { lines.append("  asked " + line) }
            lines.append("  image \(LayoutWatch.imageBase)")
            return lines.joined(separator: "\n")
        }

        var bench: [String: Any] {
            ["window": window, "views": views, "from": from, "passes": passes, "looped": looped, "dirty": dirty, "asked": asked,
             "written": written, "text": text]
        }
    }

    private final class Watching {
        weak var window: NSWindow?
        let id: ObjectIdentifier
        var report: Report
        var frames: [ObjectIdentifier: NSRect] = [:]
        var tally: [String: Int] = [:]
        var order: [String] = []
        var stacks = 0

        init(window: NSWindow, report: Report) {
            self.window = window
            id = ObjectIdentifier(window)
            self.report = report
        }
    }

    private(set) static var reports: [Report] = []
    private(set) static var made = 0
    private static var started = false
    private static var turn = 0
    private static var counts: [ObjectIdentifier: (cycle: UInt, passes: Int)] = [:]
    private static var kicked: [ObjectIdentifier: (at: CFAbsoluteTime, wait: Double)] = [:]
    private static var watching: Watching?
    private static var hooked = false
    private static var writes = 0

    nonisolated static let imageBase: String = {
        var info = Dl_info()
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "main"), dladdr(symbol, &info) != 0, let base = info.dli_fbase else {
            return "?"
        }
        return String(format: "0x%lx", UInt(bitPattern: base))
    }()

    static func start() {
        guard !started else { return }
        started = true
        UserDefaults.standard.register(defaults: [assertKey: false])
        exchange(NSWindow.self, #selector(NSWindow.layoutIfNeeded), #selector(NSWindow.layoutWatchLayoutIfNeeded))
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeTimers.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { LayoutWatch.turned() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func clear() {
        reports.removeAll()
        writes = 0
    }

    static func fill(_ count: Int) {
        for _ in 0..<count { keep(Report(window: "filler", views: 0, from: 0, passes: 0, dirty: [], asked: [])) }
    }

    private static func keep(_ report: Report) {
        made += 1
        reports.append(report)
        if reports.count > kept { reports.removeFirst(reports.count - kept) }
    }

    private static func exchange(_ kind: AnyClass, _ first: Selector, _ second: Selector) {
        guard let one = class_getInstanceMethod(kind, first), let other = class_getInstanceMethod(kind, second) else { return }
        method_exchangeImplementations(one, other)
    }

    private static func turned() {
        turn &+= 1
        if counts.count > 64 { counts.removeAll(keepingCapacity: true) }
        guard let watching else { return }
        finish(watching)
    }

    private typealias CycleCall = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias NumberCall = @convention(c) (AnyObject, Selector) -> UInt

    private static let cycleClass: AnyClass? = {
        guard let kind: AnyClass = NSClassFromString("NSDisplayCycle"),
              class_getClassMethod(kind, NSSelectorFromString("currentDisplayCycle")) != nil,
              class_getInstanceMethod(kind, NSSelectorFromString("identifier")) != nil else { return nil }
        return kind
    }()

    private static var cycle: UInt {
        guard let kind = cycleClass else { return UInt(truncatingIfNeeded: turn) }
        let current = NSSelectorFromString("currentDisplayCycle")
        let identifier = NSSelectorFromString("identifier")
        guard let method = class_getClassMethod(kind, current),
              let now = unsafeBitCast(method_getImplementation(method), to: CycleCall.self)(kind, current),
              let read = class_getInstanceMethod(kind, identifier) else { return UInt(truncatingIfNeeded: turn) }
        return unsafeBitCast(method_getImplementation(read), to: NumberCall.self)(now, identifier)
    }

    fileprivate static func pass(_ window: NSWindow) {
        guard fromDisplayCycle() else { return }
        let id = ObjectIdentifier(window)
        let now = cycle
        var count = 1
        if let last = counts[id], last.cycle == now { count = last.passes + 1 }
        counts[id] = (now, count)
        guard count >= alarm else { return }
        watch(window, id, count)
    }

    private static func few(_ window: NSWindow) -> Bool {
        guard let top = window.contentView?.superview ?? window.contentView else { return true }
        var left = late
        var stack = [top]
        while let view = stack.popLast() {
            left -= 1
            if left <= 0 { return false }
            stack.append(contentsOf: view.subviews)
        }
        return true
    }

    private static func watch(_ window: NSWindow, _ id: ObjectIdentifier, _ count: Int) {
        if let watching {
            guard watching.id == id else { return }
            watching.report.passes = count
            let names = dirty(in: window, watching)
            let before = watching.report.dirty.last ?? []
            if watching.report.dirty.count < 3 { watching.report.dirty.append(names) }
            if count > watching.report.views, !watching.report.written, !names.isEmpty, !before.isEmpty { write(watching) }
            return
        }
        guard count >= late || few(window), let top = window.contentView?.superview ?? window.contentView else { return }
        var views = 0
        walk(top) { _ in views += 1 }
        let size = window.frame.size
        let made = Watching(window: window, report: Report(window: "\(type(of: window)) \(Int(size.width))×\(Int(size.height))", views: views,
                                                           from: count, passes: count, dirty: [], asked: []))
        made.report.dirty.append(dirty(in: window, made))
        watching = made
        hook(true)
    }

    private static func finish(_ watching: Watching) {
        hook(false)
        self.watching = nil
        watching.report.asked = asked(watching)
        var stuck = false
        if watching.report.passes > watching.report.views, let window = watching.window,
           let top = window.contentView?.superview ?? window.contentView {
            walk(top) { if $0.needsLayout { stuck = true } }
        }
        watching.report.looped = stuck
        if stuck, !watching.report.written { write(watching) }
        keep(watching.report)
        guard stuck, let window = watching.window else { return }
        let now = CFAbsoluteTimeGetCurrent()
        var wait = 0.0
        if let last = kicked[watching.id], now - last.at < last.wait + 2 { wait = min(1, max(0.25, last.wait * 2)) }
        kicked[watching.id] = (now, wait)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak window] in window?.layoutIfNeeded() }
    }

    private static func write(_ watching: Watching) {
        watching.report.asked = asked(watching)
        watching.report.written = true
        guard writes < 8 else { return }
        writes += 1
        Links.noteTrouble(watching.report.text)
    }

    private static func asked(_ watching: Watching) -> [String] {
        watching.order.prefix(12).map { "\(watching.tally[$0] ?? 0)× \($0)" }
    }

    private static func hook(_ on: Bool) {
        guard hooked != on else { return }
        hooked = on
        exchange(NSView.self, #selector(setter: NSView.needsLayout), #selector(NSView.layoutWatchSetNeedsLayout(_:)))
    }

    private static func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for child in view.subviews { walk(child, visit) }
    }

    private static func dirty(in window: NSWindow, _ watching: Watching) -> [String] {
        guard let top = window.contentView?.superview ?? window.contentView else { return [] }
        var names: [String] = []
        var frames: [ObjectIdentifier: NSRect] = [:]
        walk(top) { view in
            guard view.needsLayout else { return }
            let id = ObjectIdentifier(view)
            frames[id] = view.frame
            guard names.count < 12 else { return }
            var name = "\(type(of: view)) \(box(view.frame))"
            if let before = watching.frames[id], before != view.frame { name += " was \(box(before))" }
            var up = view.superview
            var depth = 0
            while let parent = up, depth < 3 {
                name += " < \(type(of: parent))"
                up = parent.superview
                depth += 1
            }
            names.append(name)
        }
        watching.frames = frames
        return names
    }

    private static func box(_ rect: NSRect) -> String {
        String(format: "{%.2f, %.2f, %.2f, %.2f}", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static var cycleStart: UInt = 0

    static var laid: ((NSWindow) -> Void)?

    static func inCycle() -> Bool { fromDisplayCycle() }

    private static func fromDisplayCycle() -> Bool {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 8)
        let found = Int(backtrace(&frames, 8))
        guard found > 2 else { return false }
        if cycleStart != 0 {
            for index in 2..<found {
                let address = UInt(bitPattern: frames[index])
                if address >= cycleStart, address - cycleStart < 2048 { return true }
            }
            return false
        }
        for index in 2..<found {
            var info = Dl_info()
            guard let frame = frames[index], dladdr(frame, &info) != 0, let name = info.dli_sname, let start = info.dli_saddr,
                  String(cString: name).contains("DisplayCycleObserverForLayout") else { continue }
            cycleStart = UInt(bitPattern: start)
            return true
        }
        return false
    }

    fileprivate static func asked(_ view: NSView) {
        guard let watching, let window = view.window, ObjectIdentifier(window) == watching.id else { return }
        var key = "\(type(of: view))"
        if watching.stacks < 60 {
            watching.stacks += 1
            key += " by " + callers()
        }
        if watching.tally[key] == nil { watching.order.append(key) }
        watching.tally[key, default: 0] += 1
    }

    private static func callers() -> String {
        var own: UnsafeMutableRawPointer?
        var names: [String] = []
        var info = Dl_info()
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "main"), dladdr(symbol, &info) != 0 { own = info.dli_fbase }
        for address in Thread.callStackReturnAddresses.dropFirst(2) {
            guard names.count < 5 else { break }
            var frame = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address.uintValue), &frame) != 0, let base = frame.dli_fbase, base == own else { continue }
            let offset = String(format: "+0x%lx", address.uintValue - UInt(bitPattern: base))
            guard let symbol = frame.dli_sname else {
                names.append(offset)
                continue
            }
            let plain = layoutWatchDemangle(symbol, UInt(strlen(symbol)), nil, nil, 0)
            let name = plain.map { String(cString: $0) } ?? String(cString: symbol)
            free(plain)
            guard !name.contains("layoutWatch") else { continue }
            names.append("\(short(name)) \(offset)")
        }
        return names.isEmpty ? "AppKit" : names.joined(separator: " ← ")
    }

    private static func short(_ name: String) -> String {
        var text = name
        for prefix in ["Search.", "Broadway."] { text = text.replacingOccurrences(of: prefix, with: "") }
        if let arrow = text.range(of: " -> ") { text = String(text[..<arrow.lowerBound]) }
        return String(text.prefix(90))
    }
}

extension NSWindow {
    @objc fileprivate func layoutWatchLayoutIfNeeded() {
        LayoutWatch.pass(self)
        layoutWatchLayoutIfNeeded()
        if let laid = LayoutWatch.laid, LayoutWatch.inCycle() { laid(self) }
    }
}

extension NSView {
    @objc fileprivate func layoutWatchSetNeedsLayout(_ flag: Bool) {
        if flag { LayoutWatch.asked(self) }
        layoutWatchSetNeedsLayout(flag)
    }
}
