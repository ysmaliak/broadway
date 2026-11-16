import AppKit
import CoreGraphics

enum Sight {
    static let most = 0.6

    static func covered(_ box: NSRect, above window: NSWindow) -> Double {
        guard box.width >= 1, box.height >= 1, window.windowNumber > 0,
              let top = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                    CGWindowID(window.windowNumber)) as? [[String: Any]]
        else { return 0 }
        let target = CGRect(x: box.minX, y: top - box.maxY, width: box.width, height: box.height)
        let over: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            let part = rect.intersection(target)
            return part.isNull || part.isEmpty ? nil : part
        }
        return share(of: target, under: over)
    }

    static func share(of target: CGRect, under rects: [CGRect]) -> Double {
        guard !rects.isEmpty, target.width > 0, target.height > 0 else { return 0 }
        let columns = 24, rows = 16
        var hit = 0
        for row in 0..<rows {
            let y = target.minY + (Double(row) + 0.5) * target.height / Double(rows)
            for column in 0..<columns {
                let x = target.minX + (Double(column) + 0.5) * target.width / Double(columns)
                if rects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { hit += 1 }
            }
        }
        return Double(hit) / Double(columns * rows)
    }
}
