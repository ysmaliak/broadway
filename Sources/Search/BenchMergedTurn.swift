import AppKit
import QuartzCore

@MainActor
enum BenchMergedTurn {
    private static var taking = false

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "mergedturn only works on a --test run"]) }
        if let hold = (request["hold"] as? NSNumber)?.doubleValue { LiveFolders.shared.mergedHold = hold }
        if let seen = request["sight"] as? Bool { browser.sightForBench = seen }
        if request.keys.contains("reduced") {
            if let on = request["reduced"] as? Bool {
                Store.settings.set(on, forKey: "motion.testReduced")
            } else {
                Store.settings.removeObject(forKey: "motion.testReduced")
            }
        }
        if let lit = (request["lit"] as? String).flatMap(URL.init(string:)), let host = browser.window?.contentView?.superview {
            host.layoutSubtreeIfNeeded()
            row(lit, in: host, browser: browser)?.benchLive = request["off"] as? Bool == true ? false : true
        }
        guard let folder = request["frames"] as? String else { return answer(report()) }
        frames(request, to: folder, browser: browser, answer)
    }

    static func report() -> [String: Any] {
        ["hold": LiveFolders.shared.mergedHold, "reduced": Motion.reduced]
    }

    private static func row(_ url: URL, in host: NSView, browser: Browser) -> TabRowView? {
        let identity = LiveIdentity.of(url.absoluteString)
        return host.kitSubviews(of: TabRowView.self).first { row in
            row.window != nil && !row.pooled && !row.isHiddenOrHasHiddenAncestor
                && row.tab?.liveKey.map(LiveIdentity.of) == identity && row.tab.map { tab in browser.tabs.contains { $0 === tab } } == true
        }
    }

    private static func frames(_ request: [String: Any], to folder: String, browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard !taking else { return answer(["error": "frames are being taken"]) }
        guard let window = browser.window, let frame = window.contentView?.superview, let root = frame.layer,
              let column = frame.kitSubviews(of: SideColumnView.self).first(where: { $0.window != nil }) else {
            return answer(["error": "mergedturn frames needs a window with a sidebar"])
        }
        let urls = (request["turn"] as? [String] ?? []).compactMap(URL.init(string:)).filter(PullPageRelay.pull)
        let times = ((request["times"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []).sorted()
        let after = ((request["after"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []).sorted()
        let scale = CGFloat((request["scale"] as? NSNumber)?.doubleValue ?? 2)
        let tall = (request["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
        var rect = column.convert(column.bounds, to: frame)
        if let tall, tall < rect.height { rect = NSRect(x: rect.minX, y: rect.maxY - tall, width: rect.width, height: tall) }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        frame.layoutSubtreeIfNeeded()
        var placed: [String: [Double]] = [:]
        var watched = urls
        for url in (request["place"] as? [String] ?? []).compactMap(URL.init(string:)) where !watched.contains(url) { watched.append(url) }
        for url in watched {
            guard let row = row(url, in: frame, browser: browser) else { continue }
            let box = row.convert(row.bounds, to: frame)
            placed[url.absoluteString] = [Double(box.minX - rect.minX), Double(rect.maxY - box.maxY), Double(box.width), Double(box.height)]
        }
        taking = true
        var shots: [(said: [String: Any], picture: NSBitmapImageRep?)] = []
        let dark = column.kitDark
        var start = CACurrentMediaTime()
        func facts() -> [[String: Any]] {
            watched.map { url in
                let shown = row(url, in: frame, browser: browser)
                return ["url": url.absoluteString, "shown": shown != nil, "plays": shown?.plays ?? 0, "arrivals": shown?.arrivals ?? 0,
                        "form": shown?.mergedForm?.rawValue ?? "", "drawn": shown?.mergedLayers ?? 0,
                        "began": shown?.mergedBegan.map { $0 - start } ?? -1, "lasts": shown?.mergedLasts ?? 0,
                        "merging": LiveFolders.shared.turning(url.absoluteString)]
            }
        }
        func shoot(_ name: String, at moment: Double) {
            shots.append((["name": name, "t": (moment * 1000).rounded() / 1000, "rows": facts()], draw(root, rect: rect, scale: scale, window: window, dark: dark)))
        }
        shoot("before", at: -1)
        start = CACurrentMediaTime()
        for url in urls { LiveFolders.shared.pageMerged(url, space: browser.spaceID) }
        if !urls.isEmpty { browser.syncLive() }
        frame.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "merged turn frames")
        var left: Double?
        func finish() {
            ProcessInfo.processInfo.endActivity(awake)
            for (index, shot) in shots.enumerated() {
                let name = String(format: "%03d.png", index)
                if let data = shot.picture?.representation(using: .png, properties: [:]),
                   (try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))) != nil {
                    shots[index].said["file"] = name
                }
            }
            taking = false
            answer(["frames": shots.map(\.said), "folder": folder, "scale": Double(scale), "rows": placed, "left": left ?? -1,
                    "size": [Double(rect.width), Double(rect.height)],
                    "hold": LiveFolders.shared.mergedHold, "dark": dark])
        }
        guard !times.isEmpty else { return finish() }
        var due = times
        var late = urls.isEmpty ? [] : after
        let lead = urls.first?.absoluteString
        let last = (times.last ?? 0) + LiveFolders.shared.mergedHold + 3
        let clock = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        clock.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        clock.setEventHandler {
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime() - start
                while let next = due.first, now >= next {
                    due.removeFirst()
                    shoot(String(format: "%.2f", next), at: now)
                }
                if left == nil, let lead, !LiveFolders.shared.turning(lead) { left = now }
                if let left {
                    while let next = late.first, now >= left + next {
                        late.removeFirst()
                        shoot(String(format: "left-%.2f", next), at: now - left)
                    }
                }
                guard (due.isEmpty && late.isEmpty) || now > last else { return }
                clock.cancel()
                finish()
            }
        }
        clock.resume()
    }

    private static func draw(_ root: CALayer, rect: NSRect, scale: CGFloat, window: NSWindow, dark: Bool) -> NSBitmapImageRep? {
        let wide = Int((rect.width * scale).rounded()), tall = Int((rect.height * scale).rounded())
        guard wide > 0, tall > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: tall, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let pen = context.cgContext
        let ground = (window.backgroundColor ?? .windowBackgroundColor).kitResolved(dark: dark).usingColorSpace(.deviceRGB) ?? .white
        pen.setFillColor(red: ground.redComponent, green: ground.greenComponent, blue: ground.blueComponent, alpha: 1)
        pen.fill(CGRect(x: 0, y: 0, width: wide, height: tall))
        pen.scaleBy(x: scale, y: scale)
        pen.translateBy(x: -rect.minX, y: -rect.minY)
        (root.presentation() ?? root).render(in: pen)
        return rep
    }
}
