import AppKit

@MainActor
enum BenchAddressPill {
    static let verbs: Set<String> = ["addresspill"]

    static func run(_ verb: String, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "addresspill only works on a --test run"]); return }
        let host = (request["url"] as? String).flatMap(URL.init(string:)).map { AddressLaneView.text($0, full: request["full"] as? Bool ?? false) }
            ?? request["host"] as? String
        let dark = request["look"] as? String == "dark"
        let width = CGFloat(request["width"] as? Double ?? Double(Metrics.side))
        let look = (request["space"] as? String).map { SpaceLook(colours: [$0], intensity: SpaceLook.real) } ?? SpaceLook()
        let scale = CGFloat(request["scale"] as? Double ?? 2)
        let stops = look.ground(dark: dark).stops
        let ground = RowGround(greys: KitGreys.frame.lit(by: stops), ink: KitInk(lift: look.inkLift(dark: dark)),
                               dark: look.inkLight(dark: dark), stops: stops)
        let pad: CGFloat = 8
        let size = NSSize(width: width, height: Metrics.sidePill + pad * 2)
        let stage = KitFlippedView(frame: NSRect(origin: .zero, size: size))
        stage.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let back = SpaceGroundView(look: look, opaque: true)
        back.spansWindow = false
        back.groundDark = dark
        back.frame = stage.bounds
        stage.addSubview(back)
        let pill = AddressPillView()
        pill.frame = NSRect(x: Metrics.sideInset, y: pad, width: width - 2 * Metrics.sideInset, height: Metrics.sidePill)
        stage.addSubview(pill)
        pill.ground = ground
        pill.words.whole = request["full"] as? Bool ?? false
        pill.host = .some(host)
        pill.layoutSubtreeIfNeeded()
        pill.show(host != nil, animated: false)
        let window = NSWindow(contentRect: stage.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = stage.appearance
        window.contentView = stage
        stage.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            stage.layoutSubtreeIfNeeded()
            let label = pill.words.label
            let runs = label.runs.map { run -> [String: Any] in
                let base = run.color ?? label.color
                let tone = base === KitColor.muted ? "muted" : base === KitColor.title ? "title" : "other"
                let drawn = label.ink.color(base, KitColor.kind(of: base), dark: ground.dark).kitResolved(dark: ground.dark)
                let alpha = Double(drawn.alphaComponent)
                return ["text": run.text, "tone": tone, "alpha": (alpha * 1000).rounded() / 1000]
            }
            var out: [String: Any] = ["runs": runs, "text": label.text, "host": host ?? NSNull(), "labelWidth": Double(label.frame.width),
                                      "labelX": Double(label.frame.minX), "pillFade": Double(SideLook.pillFade),
                                      "fadeAt": pill.words.fadeAt.map(Double.init) ?? NSNull()]
            if let path = request["path"] as? String,
               let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                picture.size = size
                stage.cacheDisplay(in: stage.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    out["saved"] = path
                } catch { out["error"] = error.localizedDescription }
            }
            window.contentView = nil
            answer(out)
        }
    }
}
