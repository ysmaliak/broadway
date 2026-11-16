import Foundation

enum WebRepo {
    static let site: URL? = {
        let files = FileManager.default
        if let asked = ProcessInfo.processInfo.environment["BROADWAY_WEB"], !asked.isEmpty {
            let found = URL(fileURLWithPath: (asked as NSString).expandingTildeInPath).appendingPathComponent("site")
            return files.fileExists(atPath: found.appendingPathComponent("index.html").path) ? found : nil
        }
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        while folder.path != "/" {
            let parent = folder.deletingLastPathComponent()
            let found = parent.appendingPathComponent("broadway-web/site")
            if files.fileExists(atPath: found.appendingPathComponent("index.html").path) { return found }
            folder = parent
        }
        return nil
    }()

    static var here: Bool { site != nil }
}
