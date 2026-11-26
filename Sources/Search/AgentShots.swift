import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

struct ShotAsk {
    var scale: Double?
    var width: Int?
    var jpeg = false
    var quality = 0.8
    var marks = false
    var ifChanged = false
    var tiles = false
    var from = 1
    var count: Int?
    var full = false
    var ref = ""

    static let margin = 16.0
    static let mostTiles = 50
    static let tilesAtOnce = 20

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func flag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return text == "true" || text == "1" }
        return false
    }

    static func read(_ arguments: [String: Any]) -> (ask: ShotAsk?, problem: String?) {
        var ask = ShotAsk()
        ask.ref = arguments["ref"] as? String ?? ""
        ask.full = flag(arguments["full"])
        ask.tiles = flag(arguments["tiles"])
        ask.marks = flag(arguments["marks"])
        ask.ifChanged = flag(arguments["if_changed"] ?? arguments["if-changed"])
        if let scale = number(arguments["scale"]) {
            guard (0.25...4).contains(scale) else { return (nil, "--scale is a number from 0.25 to 4: 1 is one pixel for each point, 2 is the screen's own pixels on a Retina screen") }
            ask.scale = scale
        }
        if let width = number(arguments["width"]) {
            guard ask.scale == nil else { return (nil, "Give --scale or --width, not both") }
            guard (64...8192).contains(width) else { return (nil, "--width is a number of pixels from 64 to 8192") }
            ask.width = Int(width.rounded())
        }
        let format = (arguments["format"] as? String ?? "png").lowercased()
        switch format {
        case "png": ask.jpeg = false
        case "jpeg", "jpg": ask.jpeg = true
        default: return (nil, "--format is png or jpeg")
        }
        if let quality = number(arguments["quality"]) {
            guard ask.jpeg else { return (nil, "--quality goes with --format jpeg") }
            guard (1...100).contains(quality) else { return (nil, "--quality is a number from 1 to 100") }
            ask.quality = quality / 100
        }
        if let from = number(arguments["from"]) {
            guard ask.tiles else { return (nil, "--from goes with --tiles") }
            guard from >= 1 else { return (nil, "--from is a tile number from 1") }
            ask.from = Int(from)
        }
        if let count = number(arguments["count"]) {
            guard ask.tiles else { return (nil, "--count goes with --tiles") }
            guard (1...Double(mostTiles)).contains(count) else { return (nil, "--count is a number of tiles from 1 to \(mostTiles)") }
            ask.count = Int(count)
        }
        let areas = [!ask.ref.isEmpty, ask.full, ask.tiles].filter { $0 }.count
        guard areas <= 1 else { return (nil, "shot takes one of a target, --full or --tiles") }
        return (ask, nil)
    }
}

enum ShotSize {
    static let plain = 1.0

    static func pixels(points: CGSize, scale: Double?, width: Int?) -> (width: Int, height: Int) {
        guard points.width > 0, points.height > 0 else { return (1, 1) }
        if let width {
            return (width, max(1, Int((points.height * Double(width) / points.width).rounded())))
        }
        let factor = scale ?? plain
        return (max(1, Int((points.width * factor).rounded())), max(1, Int((points.height * factor).rounded())))
    }

    static func around(_ rect: CGRect, margin: Double, within bounds: CGRect) -> CGRect {
        rect.insetBy(dx: -margin, dy: -margin).intersection(bounds).integral
    }

    static func tiles(page: Double, view: Double, overlap: Double) -> (step: Double, count: Int) {
        let step = max(1, view - overlap)
        let reach = max(0, page - view)
        return (step, 1 + Int((reach / step).rounded(.up)))
    }

    static func overlap(view: Double) -> Double {
        min(80, max(40, (view / 10).rounded()))
    }
}

enum ShotPixels {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func canvas(_ image: CGImage, width: Int, height: Int) -> CGContext? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    static func encode(_ image: CGImage, jpeg: Bool, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func changed(_ old: CGImage, _ new: CGImage, tolerance: Int = 8) -> Double? {
        guard old.width == new.width, old.height == new.height, let a = canvas(old, width: old.width, height: old.height),
              let b = canvas(new, width: new.width, height: new.height), let left = a.data, let right = b.data else { return nil }
        let count = old.width * old.height
        let one = left.bindMemory(to: UInt8.self, capacity: count * 4)
        let two = right.bindMemory(to: UInt8.self, capacity: count * 4)
        var differ = 0
        for pixel in 0..<count {
            let at = pixel * 4
            if abs(Int(one[at]) - Int(two[at])) > tolerance || abs(Int(one[at + 1]) - Int(two[at + 1])) > tolerance
                || abs(Int(one[at + 2]) - Int(two[at + 2])) > tolerance { differ += 1 }
        }
        return Double(differ) / Double(max(count, 1))
    }

    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value == 0 { return "0%" }
        if value < 0.1 { return "under 0.1%" }
        return String(format: "%.1f%%", value)
    }
}

@MainActor
enum ShotMemory {
    static let unchangedBelow = 0.005
    static let mostPixels = 16_000_000
    private static var kept: [(key: String, image: CGImage)] = []

    static func key(_ task: UUID?, _ tab: Tab, _ area: String) -> String {
        "\(task.map { $0.uuidString } ?? "-")|\(tab.id.uuidString)|\(area)"
    }

    static func last(_ key: String) -> CGImage? { kept.last { $0.key == key }?.image }

    static func keep(_ key: String, _ image: CGImage) {
        kept.removeAll { $0.key == key }
        kept.append((key, image))
        var total = kept.reduce(0) { $0 + $1.image.width * $1.image.height }
        while total > mostPixels, kept.count > 1 {
            total -= kept[0].image.width * kept[0].image.height
            kept.removeFirst()
        }
    }
}

struct ShotMark {
    var ref: String
    var rect: CGRect
}

enum ShotMarks {
    static let ink = CGColor(srgbRed: 0.82, green: 0.0, blue: 0.42, alpha: 1)

    static func draw(_ marks: [ShotMark], on context: CGContext, height: Int) {
        let size = 11.0
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphics
        var taken: [CGRect] = []
        context.setLineWidth(1)
        for mark in marks {
            let box = CGRect(x: mark.rect.minX, y: Double(height) - mark.rect.maxY, width: mark.rect.width, height: mark.rect.height)
            context.setStrokeColor(ink.copy(alpha: 0.85) ?? ink)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            let text = NSAttributedString(string: mark.ref, attributes: attributes)
            let measured = text.size()
            let label = CGSize(width: ceil(measured.width) + 6, height: ceil(measured.height) + 2)
            let spots = [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX - label.width - 1, y: box.maxY - label.height),
                         CGPoint(x: box.minX, y: box.minY - label.height), CGPoint(x: box.minX, y: box.maxY - label.height)]
            let canvas = CGRect(x: 0, y: 0, width: context.width, height: context.height)
            var place = CGRect(origin: spots[3], size: label)
            for spot in spots {
                let tried = CGRect(origin: spot, size: label)
                if canvas.contains(tried), !taken.contains(where: { $0.intersects(tried) }) { place = tried; break }
            }
            place.origin.x = min(max(0, place.origin.x), canvas.width - label.width)
            place.origin.y = min(max(0, place.origin.y), canvas.height - label.height)
            taken.append(place)
            let path = CGPath(roundedRect: place, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.addPath(path)
            context.setFillColor(ink)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
            context.setLineWidth(1)
            context.strokePath()
            text.draw(at: CGPoint(x: place.minX + 3, y: place.minY + 1))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static let script = AgentPage.walkBase + """

    var st = broadwayState();
    var walked = broadwayWalk(document.body, { cap: 2000 });
    var found = [];
    walked.rows.forEach(function (row) {
      if (!row.item || row.landmark) return;
      var ref = row.item.ref;
      broadwayTell(ref);
      var el = st.map[ref];
      if (!el || !el.isConnected) return;
      var r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return;
      if (r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) return;
      found.push({ ref: ref, role: row.item.role || '', x: r.left, y: r.top, width: r.width, height: r.height });
    });
    return { doc: st.doc, marks: found, width: innerWidth, height: innerHeight };
    """
}

enum ShotTiles {
    static let startScript = """
    var was = { x: scrollX, y: scrollY };
    window.__broadwayTiles = { was: was, hid: [], natural: [] };
    var all = document.querySelectorAll('*');
    window.scrollTo({ left: scrollX, top: 0, behavior: 'instant' });
    for (var i = 0; i < all.length; i++) {
      var el = all[i], position = getComputedStyle(el).position;
      if (position === 'sticky' || position === '-webkit-sticky') window.__broadwayTiles.natural.push([el, el.getBoundingClientRect().top + scrollY]);
    }
    var d = document.documentElement, b = document.body || d;
    return { x: was.x, y: was.y, width: innerWidth, view: innerHeight, page: Math.max(d.scrollHeight, b.scrollHeight, innerHeight) };
    """

    static let tileScript = """
    var t = window.__broadwayTiles || { hid: [], natural: [] };
    function show() {
      for (var h = 0; h < t.hid.length; h++) {
        var one = t.hid[h];
        one[0].style.removeProperty('visibility');
        if (one[1]) one[0].style.setProperty('visibility', one[1], one[2]);
      }
      t.hid = [];
    }
    show();
    window.scrollTo({ left: scrollX, top: offset, behavior: 'instant' });
    await new Promise(function (done) { requestAnimationFrame(function () { requestAnimationFrame(done); }); });
    var until = Date.now() + wait;
    function waiting() {
      var pics = document.images, left = 0;
      for (var p = 0; p < pics.length; p++) {
        var pic = pics[p];
        if (pic.complete) continue;
        var r = pic.getBoundingClientRect();
        if (r.bottom > 0 && r.top < innerHeight && r.width > 0) left++;
      }
      return left;
    }
    while (waiting() > 0 && Date.now() < until) await new Promise(function (done) { setTimeout(done, 50); });
    if (scrollY > 0) {
      var natural = new Map(t.natural);
      var all = document.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i], s = getComputedStyle(el), position = s.position;
        if (position !== 'fixed' && position !== 'sticky' && position !== '-webkit-sticky') continue;
        if (s.visibility === 'hidden' || s.display === 'none') continue;
        var r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1 || r.bottom <= 0 || r.top >= innerHeight) continue;
        if (r.width * r.height >= innerWidth * innerHeight * 0.6) continue;
        if (position !== 'fixed') {
          var home = natural.get(el);
          if (home !== undefined && Math.abs(home - (r.top + scrollY)) < 2) continue;
        }
        var inside = false;
        for (var k = 0; k < t.hid.length; k++) if (t.hid[k][0].contains(el)) { inside = true; break; }
        if (inside) continue;
        t.hid.push([el, el.style.getPropertyValue('visibility'), el.style.getPropertyPriority('visibility')]);
        el.style.setProperty('visibility', 'hidden', 'important');
      }
    }
    await new Promise(function (done) { requestAnimationFrame(function () { requestAnimationFrame(done); }); });
    var d = document.documentElement, b = document.body || d;
    return { y: scrollY, page: Math.max(d.scrollHeight, b.scrollHeight, innerHeight), view: innerHeight, hid: t.hid.length };
    """

    static let endScript = """
    var t = window.__broadwayTiles;
    if (!t) return false;
    for (var h = 0; h < t.hid.length; h++) {
      var one = t.hid[h];
      one[0].style.removeProperty('visibility');
      if (one[1]) one[0].style.setProperty('visibility', one[1], one[2]);
    }
    window.scrollTo({ left: t.was.x, top: t.was.y, behavior: 'instant' });
    delete window.__broadwayTiles;
    return true;
    """
}

extension BrowserToolbox {
    struct ShotTaken {
        var image: CGImage
        var marks: [ShotMark] = []
    }

    func capture(_ web: WKWebView, rect: CGRect?, pixels: (width: Int, height: Int)) async -> CGImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        if let rect { configuration.rect = rect }
        let backing = web.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let points = rect?.width ?? web.bounds.width
        if abs(points * backing - Double(pixels.width)) >= 1 {
            configuration.snapshotWidth = NSNumber(value: Double(pixels.width) / Double(max(backing, 1)))
        }
        let image: NSImage? = await withCheckedContinuation { done in
            web.takeSnapshot(with: configuration) { image, _ in done.resume(returning: image) }
        }
        guard let image else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let picture = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        if picture.width == pixels.width, picture.height == pixels.height { return picture }
        return ShotPixels.canvas(picture, width: pixels.width, height: pixels.height)?.makeImage()
    }

    func marks(_ tab: Tab, area: CGRect, pixels: (width: Int, height: Int)) async -> (marks: [ShotMark], told: [[String: Any]]) {
        guard let said = await timed(tab, ShotMarks.script, [:], seconds: 8) as? [String: Any], let list = said["marks"] as? [[String: Any]] else { return ([], []) }
        let zoom = max(tab.web.pageZoom, 0.1)
        let factor = Double(pixels.width) / max(area.width, 1)
        var marks: [ShotMark] = []
        var told: [[String: Any]] = []
        for item in list {
            guard let ref = item["ref"] as? String else { continue }
            let x = (item["x"] as? Double ?? 0) * zoom, y = (item["y"] as? Double ?? 0) * zoom
            let width = (item["width"] as? Double ?? 0) * zoom, height = (item["height"] as? Double ?? 0) * zoom
            let box = CGRect(x: x, y: y, width: width, height: height).intersection(area)
            guard !box.isEmpty, box.width >= 1, box.height >= 1 else { continue }
            let drawn = CGRect(x: (box.minX - area.minX) * factor, y: (box.minY - area.minY) * factor, width: box.width * factor, height: box.height * factor)
            marks.append(ShotMark(ref: ref, rect: drawn))
            told.append(["ref": ref, "role": item["role"] as? String ?? "", "x": Int(drawn.midX.rounded()), "y": Int(drawn.midY.rounded())])
        }
        return (marks, told)
    }

    func finish(_ taken: ShotTaken, ask: ShotAsk, key: String) -> (data: Data?, unchanged: Double?, width: Int, height: Int) {
        let width = taken.image.width, height = taken.image.height
        let old = ShotMemory.last(key)
        ShotMemory.keep(key, taken.image)
        if ask.ifChanged, let old, let fraction = ShotPixels.changed(old, taken.image), fraction < ShotMemory.unchangedBelow {
            return (nil, fraction, width, height)
        }
        var picture = taken.image
        if !taken.marks.isEmpty, let context = ShotPixels.canvas(taken.image, width: width, height: height) {
            ShotMarks.draw(taken.marks, on: context, height: height)
            picture = context.makeImage() ?? picture
        }
        return (ShotPixels.encode(picture, jpeg: ask.jpeg, quality: ask.quality), nil, width, height)
    }

    func shot(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        let read = ShotAsk.read(arguments)
        guard let ask = read.ask else { return .failure(read.problem ?? "That shot can't be taken", code: .usage) }
        if ask.tiles { return await tiles(tab, ask, task: task) }
        if !ask.ref.isEmpty, AgentRef(ask.ref).frame != nil { return .failure("A picture of one element in a frame is not supported. Take the whole page.") }
        if ask.full, let refused = notMine(tab, task: task) { return refused }
        if ask.full, !tab.agent { return .failure("A full-page picture needs a tab of your own: the person's page is never resized. Use open.", code: .notYours) }
        let web = tab.web
        let kept = (frame: web.frame, mask: web.autoresizingMask)
        var rect = web.bounds
        var area = "view"
        if !ask.ref.isEmpty {
            let (spotted, failure) = await spot(tab, ref: ask.ref)
            if let failure { return failure }
            let left = spotted?["left"] as? Double ?? 0, top = spotted?["top"] as? Double ?? 0
            let width = spotted?["width"] as? Double ?? 0, height = spotted?["height"] as? Double ?? 0
            let zoom = max(web.pageZoom, 0.1)
            let bounds = web.bounds
            let element = CGRect(x: left * zoom, y: top * zoom, width: width * zoom, height: height * zoom)
            let around = ShotSize.around(element, margin: ShotAsk.margin, within: CGRect(origin: .zero, size: bounds.size))
            if around.isEmpty { return .failure("That element is outside the page's view") }
            rect = web.isFlipped ? around : CGRect(x: around.minX, y: bounds.height - around.maxY, width: around.width, height: around.height)
            area = "ref:" + ask.ref
        }
        guard await AgentPage.shield(tab) else { return .failure("That page can't be pictured safely") }
        var tall: (page: Double, shown: Double)?
        if ask.full, let size = await PageSelection.run(tab, AgentPage.pageSizeScript) as? [String: Any] {
            let page = (size["height"] as? Double ?? kept.frame.height) * max(web.pageZoom, 0.1)
            let height = min(page, Self.tallest)
            if page > height { tall = (page, height) }
            web.autoresizingMask = []
            web.setFrameSize(NSSize(width: kept.frame.width, height: max(height, kept.frame.height)))
            try? await Task.sleep(for: .milliseconds(300))
            rect = web.bounds
            area = "full"
        }
        let pixels = ShotSize.pixels(points: rect.size, scale: ask.scale, width: ask.width)
        let image = await capture(web, rect: ask.ref.isEmpty && !ask.full ? nil : rect, pixels: pixels)
        var drawn: (marks: [ShotMark], told: [[String: Any]]) = ([], [])
        if ask.marks, image != nil {
            let flipped = web.isFlipped ? rect : CGRect(x: rect.minX, y: web.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            drawn = await marks(tab, area: flipped, pixels: pixels)
        }
        if ask.full {
            web.frame = kept.frame
            web.autoresizingMask = kept.mask
        }
        _ = await PageSelection.run(tab, AgentPage.unshieldScript)
        guard let image else { return .failure("No picture of that page") }
        let done = finish(ShotTaken(image: image, marks: drawn.marks), ask: ask, key: ShotMemory.key(task, tab, area))
        var data: [String: Any] = ["width": done.width, "height": done.height, "format": ask.jpeg ? "jpeg" : "png"]
        if ask.ref.isEmpty, !ask.full { tookShot(tab, task: task, scale: Double(done.width) / max(rect.width, 1)) }
        if !drawn.told.isEmpty || ask.marks { data["marks"] = drawn.told }
        if let fraction = done.unchanged {
            data["unchanged"] = true
            data["changed"] = ShotPixels.percent(fraction)
            return ToolOutcome(text: "Unchanged since your last shot of this tab (\(ShotPixels.percent(fraction)) of pixels)", data: data)
        }
        guard let bytes = done.data else { return .failure("No picture of that page") }
        var outcome = ToolOutcome(imagePNG: bytes)
        outcome.imageType = ask.jpeg ? "image/jpeg" : "image/png"
        outcome.data = data
        outcome.text = Self.sized(done.width, done.height, jpeg: ask.jpeg, marks: ask.marks ? drawn.told.count : nil)
        if let tall {
            let line = Self.cutLine(page: tall.page, shown: tall.shown)
            outcome.text = (outcome.text ?? "") + "\n" + line
            outcome.data?["warning"] = line
            outcome.data?["page_height"] = Int(tall.page.rounded())
        }
        return outcome
    }

    static let tallest: Double = 16_000

    static func cutLine(page: Double, shown: Double) -> String {
        let whole = { (value: Double) in Int(value.rounded()).formatted(.number.grouping(.never)) }
        return "The page is \(whole(page)) points tall and the picture stops at \(whole(shown)). For the rest, broadway shot --tiles, or scroll to it, then broadway shot."
    }

    static func sized(_ width: Int, _ height: Int, jpeg: Bool, marks: Int?) -> String {
        var said = "\(width) by \(height) pixels, \(jpeg ? "JPEG" : "PNG")"
        if let marks { said += marks == 0 ? ". No refs in view to mark" : ", \(marks) ref\(marks == 1 ? "" : "s") marked" }
        return said
    }

    func tiles(_ tab: Tab, _ ask: ShotAsk, task: UUID?) async -> ToolOutcome {
        if let refused = notMine(tab, task: task) { return refused }
        guard tab.agent else { return .failure("Tiles need a tab of your own, since the person's page is never scrolled under them. Use open.", code: .notYours) }
        let web = tab.web
        guard let start = await PageSelection.run(tab, ShotTiles.startScript) as? [String: Any] else { return .failure("The page gave no answer", code: .noAnswer) }
        let zoom = max(web.pageZoom, 0.1)
        var view = start["view"] as? Double ?? web.bounds.height / zoom
        var page = start["page"] as? Double ?? view
        let overlap = ShotSize.overlap(view: view)
        var plan = ShotSize.tiles(page: page, view: view, overlap: overlap)
        let last = min(ask.from - 1 + (ask.count ?? ShotAsk.tilesAtOnce), ShotAsk.mostTiles)
        var made: [[String: Any]] = []
        var pictures: [Data] = []
        var folder: URL?
        var lastY = -1.0
        var stuck = false
        var safe = true
        var index = ask.from
        while index <= min(plan.count, last) {
            let wanted = min(Double(index - 1) * plan.step, max(0, page - view))
            guard let said = await PageSelection.run(tab, ShotTiles.tileScript, ["offset": wanted, "wait": 1500]) as? [String: Any] else { break }
            let y = said["y"] as? Double ?? wanted
            if index > ask.from, abs(y - lastY) < 1 { stuck = true; break }
            if index == 1, ask.from == 1, abs(y - wanted) > 1, wanted > 0 { stuck = true }
            lastY = y
            view = said["view"] as? Double ?? view
            page = said["page"] as? Double ?? page
            plan = ShotSize.tiles(page: page, view: view, overlap: overlap)
            guard await AgentPage.shield(tab) else { safe = false; break }
            let rect = web.bounds
            let pixels = ShotSize.pixels(points: rect.size, scale: ask.scale, width: ask.width)
            guard let image = await capture(web, rect: nil, pixels: pixels) else { break }
            var drawn: (marks: [ShotMark], told: [[String: Any]]) = ([], [])
            if ask.marks {
                let flipped = CGRect(origin: .zero, size: rect.size)
                drawn = await marks(tab, area: flipped, pixels: pixels)
            }
            _ = await PageSelection.run(tab, AgentPage.unshieldScript)
            let done = finish(ShotTaken(image: image, marks: drawn.marks), ask: ask,
                              key: ShotMemory.key(task, tab, "tile:\(Int(y.rounded()))"))
            var row: [String: Any] = ["tile": index, "offset": Int(y.rounded()), "width": done.width, "height": done.height]
            if ask.marks { row["marks"] = drawn.told }
            if let fraction = done.unchanged {
                row["unchanged"] = true
                row["changed"] = ShotPixels.percent(fraction)
            } else if let bytes = done.data {
                if folder == nil { folder = try? Self.privateFolder("broadway-tiles-") }
                guard let folder else { break }
                let file = folder.appendingPathComponent(String(format: "tile-%02d.%@", index, ask.jpeg ? "jpg" : "png"))
                do {
                    try bytes.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                } catch { break }
                row["path"] = file.path
                row["bytes"] = bytes.count
                pictures.append(bytes)
            }
            made.append(row)
            if stuck { break }
            index += 1
        }
        _ = await PageSelection.run(tab, AgentPage.unshieldScript)
        _ = await PageSelection.run(tab, ShotTiles.endScript)
        guard safe else { return .failure("That page can't be pictured safely") }
        guard !made.isEmpty else {
            if ask.from > plan.count { return .failure("The page has \(plan.count) tile\(plan.count == 1 ? "" : "s"), so there is no tile \(ask.from)", code: .usage) }
            return .failure("No picture of that page")
        }
        let total = stuck ? made.count + ask.from - 1 : plan.count
        let first = made.first?["tile"] as? Int ?? ask.from
        let end = made.last?["tile"] as? Int ?? first
        var data: [String: Any] = ["tiles": made, "total": total, "from": first, "to": end, "overlap": Int(overlap.rounded()),
                                   "format": ask.jpeg ? "jpeg" : "png"]
        if let folder { data["folder"] = folder.path }
        if stuck { data["stuck"] = true }
        var lines = [first == 1 && end == total ? "The page is \(total) tile\(total == 1 ? "" : "s") high" : "Tiles \(first) to \(end) of \(total)"]
        for row in made {
            let number = row["tile"] as? Int ?? 0, offset = row["offset"] as? Int ?? 0
            if row["unchanged"] as? Bool == true {
                lines.append("tile \(number) at \(offset): unchanged since your last shot of it (\(row["changed"] as? String ?? "0%") of pixels)")
            } else {
                lines.append("tile \(number) at \(offset): \(row["width"] as? Int ?? 0) by \(row["height"] as? Int ?? 0) pixels")
            }
        }
        if stuck { lines.append("The page doesn't scroll as a whole, so this is all of it that tiles can show. Scroll its own part with broadway scroll --in @ref, then shot.") }
        if end < total { lines.append("More: broadway shot --tiles --from \(end + 1)") }
        data["said"] = lines
        var outcome = ToolOutcome(text: lines.joined(separator: "\n"), data: data)
        outcome.pictures = pictures
        outcome.imageType = ask.jpeg ? "image/jpeg" : "image/png"
        return outcome
    }

    func uploadGiven(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        let paths = (arguments["paths"] as? [Any] ?? []).compactMap { $0 as? String }.map { URL(fileURLWithPath: $0) }
        guard let folder = AgentGiven.folder(arguments, paths: paths) else { return await upload(tab, arguments, task: task) }
        let outcome = await upload(tab, arguments, task: task)
        if outcome.failed { AgentGiven.drop(folder) } else { AgentGiven.keep(folder, tab: tab) }
        return outcome
    }

    static func privateFolder(_ prefix: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }
}

@MainActor
enum AgentGiven {
    static let prefix = "broadway-stdin-"
    static let longest: TimeInterval = 3600
    private static var kept: [(folder: URL, tab: UUID, since: Date)] = []
    private static var watching: Task<Void, Never>?

    static var root: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0 else { return FileManager.default.temporaryDirectory.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
    }

    static func folder(_ arguments: [String: Any], paths: [URL]) -> URL? {
        guard let text = arguments["given"] as? String, !text.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().path == root.path, folder.lastPathComponent.hasPrefix(prefix), !paths.isEmpty,
              paths.allSatisfy({ $0.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == folder.path }) else { return nil }
        return folder
    }

    static func drop(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    static func holds(_ folder: URL) -> Bool {
        kept.contains { $0.folder.standardizedFileURL.path == folder.standardizedFileURL.path }
    }

    static func keep(_ folder: URL, tab: Tab) {
        kept.append((folder, tab.id, Date()))
        guard watching == nil else { return }
        watching = Task { @MainActor in
            while !kept.isEmpty {
                try? await Task.sleep(for: .seconds(20))
                sweep()
            }
            watching = nil
        }
    }

    static func sweep(now: Date = Date()) {
        let open = Set(Browsers.all.flatMap { ($0.tabs + $0.parkedAgentTabs).map(\.id) })
        kept.removeAll { entry in
            let done = !open.contains(entry.tab) || now.timeIntervalSince(entry.since) > longest
            if done { drop(entry.folder) }
            return done
        }
    }
}
