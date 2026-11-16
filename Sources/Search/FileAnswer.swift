import Foundation
import WebKit

struct Speculation {
    let download: WKDownload
    let opener: UUID
    let url: URL
}

struct HeldTabUnder {
    let spawn: PopupSpawn
    let url: URL
    let navigation: WKNavigationType
}

enum FileAnswer {
    static let fileKinds: Set<String> = [
        "zip", "dmg", "pkg", "mpkg", "exe", "msi", "msix", "7z", "rar", "gz", "tgz", "bz2", "xz", "zst", "tar", "iso", "img",
        "apk", "aab", "ipa", "deb", "rpm", "appimage", "flatpak", "snap", "jar", "bin", "torrent", "pdf", "epub", "mobi",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "csv", "rtf", "pages", "numbers", "key",
        "mp3", "m4a", "flac", "wav", "ogg", "mp4", "m4v", "mov", "mkv", "avi", "webm", "srt", "ttf", "otf", "woff2",
        "psd", "ai", "sketch", "fig", "blend", "stl", "obj", "dwg", "safariextz", "crx", "xpi", "vsix", "whl", "gem",
        "nupkg", "sig", "asc", "sha256", "ics", "vcf", "kml", "gpx", "sqlite", "db", "dat", "cab", "vhd", "vmdk", "ova",
    ]

    static func attachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
    }

    static func navigationIsFile(_ response: URLResponse, canShow: Bool) -> Bool {
        attachment(response) || !canShow
    }

    static func fetchedIsFile(_ response: URLResponse) -> Bool {
        if attachment(response) { return true }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return false }
        let kind = (response.mimeType ?? "").lowercased()
        return !["text/html", "application/xhtml+xml", "text/plain", ""].contains(kind)
    }

    static func namesFile(_ url: URL?) -> Bool {
        guard let url else { return false }
        func named(_ text: String) -> Bool {
            let last = text.split(separator: "/").last.map(String.init) ?? text
            guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return false }
            return fileKinds.contains(last[last.index(after: dot)...].lowercased())
        }
        if named(url.path()) { return true }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap(\.value) ?? []
        return values.contains { named($0.removingPercentEncoding ?? $0) }
    }
}
