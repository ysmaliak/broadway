import AppKit

@MainActor
enum FolderGridBench {
    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "foldergrid only works on a --test run"]); return }
        if request["make"] as? Bool == true { Command.named("tabs.newFolder")?.run(browser) }
        let undo = browser.window?.undoManager
        if let undo, request["undoMark"] as? Bool == true, undo.groupingLevel > 0 {
            undo.endUndoGrouping()
            undo.beginUndoGrouping()
        }
        if let undo, request["undo"] as? Bool == true {
            let open = undo.groupingLevel > 0
            if open { undo.endUndoGrouping() }
            undo.undo()
            if open { undo.beginUndoGrouping() }
        }
        guard let content = browser.window?.contentView else { answer(["error": "no window"]); return }
        if let seconds = request["sample"] as? Double {
            guard let page = content.kitSubviews(of: SidePageView.self).first(where: { !$0.embedded && !$0.isHiddenOrHasHiddenAncestor }) else {
                answer(["error": "no side page"]); return
            }
            let start = ProcessInfo.processInfo.systemUptime
            var samples: [[String: Any]] = []
            var pictures: [CGImage] = []
            let folder = (request["frames"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
            let wide = request["width"] as? Double ?? 280
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let now = ProcessInfo.processInfo.systemUptime - start
                    var sample = page.benchCarry()
                    sample["t"] = (now * 1000).rounded()
                    if folder != nil, samples.count % 2 == 0, let picture = picture(of: page, width: wide) {
                        sample["frame"] = pictures.count
                        pictures.append(picture)
                    }
                    samples.append(sample)
                    if now >= seconds {
                        timer.invalidate()
                        if let folder {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            for (index, picture) in pictures.enumerated() {
                                let rep = NSBitmapImageRep(cgImage: picture)
                                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "%04d.png", index)))
                            }
                        }
                        answer(["samples": samples])
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        content.layoutSubtreeIfNeeded()
        func placed(_ view: NSView) -> [Double] {
            let rect = view.convert(view.bounds, to: content)
            let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
            return [rect.minX, top, rect.width, rect.height].map { Double($0) }
        }
        func seen(_ view: NSView) -> Bool { view.window != nil && !view.isHiddenOrHasHiddenAncestor }
        let groups = browser.tabGroups
        let headings = content.kitSubviews(of: GroupHeadingView.self).filter(seen).compactMap { heading -> [String: Any]? in
            guard let group = heading.group, groups.contains(where: { $0.id == group.id }) else { return nil }
            var out: [String: Any] = [
                "name": group.name, "depth": heading.depth, "collapsed": group.collapsed,
                "kind": group.live ? "live" : group.query != nil ? "search" : group.ai ? "ai" : "hand",
                "raised": FolderTree.raised(group.id, in: groups), "editing": browser.editingGroupID == group.id,
                "emoji": group.icon?.emoji ?? "", "frame": placed(heading), "nameWidth": Double(heading.benchNameWidth),
            ]
            for (key, view) in heading.benchParts where seen(view) { out[key] = placed(view) }
            return out
        }
        let rows = content.kitSubviews(of: TabRowView.self).filter(seen).compactMap { row -> [String: Any]? in
            guard let tab = row.tab else { return nil }
            var out: [String: Any] = ["id": Bench.short(tab), "label": tab.label, "frame": placed(row),
                                      "folder": browser.group(of: tab).flatMap { id in groups.first { $0.id == id }?.name } ?? ""]
            if let mark = row.kitSubviews(of: RowMarkView.self).first(where: seen) { out["icon"] = placed(mark) }
            if let title = row.kitSubviews(of: RowTitleView.self).first(where: seen) { out["title"] = placed(title) }
            return out
        }
        let splits = content.kitSubviews(of: SplitSignView.self).filter(seen).map { sign -> [String: Any] in
            ["left": Bench.short(sign.left), "right": Bench.short(sign.right), "frame": placed(sign),
             "alpha": Double(sign.alphaValue),
             "folder": browser.group(of: sign.left).flatMap { id in groups.first { $0.id == id }?.name } ?? "",
             "chips": sign.item.chips.map(placed)]
        }
        answer(["headings": headings, "rows": rows, "splits": splits, "blocks": SidePageView.benchBlocks, "drop": SidePageView.benchDrop,
                "undo": ["level": undo?.groupingLevel ?? -1, "name": undo?.undoActionName ?? "", "can": undo?.canUndo ?? false],
                "edges": ["top": ColumnEdges.seen["top"] ?? 0, "bottom": ColumnEdges.seen["bottom"] ?? 0],
                "items": browser.listItems(browser.displayedTabs).map { item -> String in
                    switch item {
                    case .tab(let id): return browser.tabs.first { $0.id == id }.map(Bench.short) ?? ""
                    case .folder(let id): return "folder:" + (groups.first { $0.id == id }?.name ?? "")
                    }
                },
                "raised": browser.pinnedFolders().map(\.name), "editing": browser.editingGroupID.flatMap { id in groups.first { $0.id == id }?.name } ?? ""])
    }

    static func picture(of content: NSView, width: Double) -> CGImage? {
        guard let root = content.layer else { return nil }
        let layer = root.presentation() ?? root
        let scale: CGFloat = 2
        let size = CGSize(width: width, height: content.bounds.height)
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        context.scaleBy(x: scale, y: scale)
        if !layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
    }
}
