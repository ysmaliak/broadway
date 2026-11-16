import AppKit
import WebKit

enum CopyForAgent {
    static let selection = "String(window.getSelection() || '')"
    @MainActor static var copied: String?

    @MainActor static func keep(_ text: String) {
        copied = text
        guard !Store.testing else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func text(title: String, url: URL?, selection: String, page: AIPage.Read?, errors: [DevEntry]) -> String? {
        let chosen = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = chosen.isEmpty ? (page?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : chosen
        guard !body.isEmpty else { return nil }
        var parts: [String] = []
        if !title.isEmpty { parts.append("Page: \(title)") }
        if let url { parts.append("URL: \(DevCopy.strip(url.absoluteString))") }
        if !chosen.isEmpty { parts.append("Selected text:") }
        var text = parts.joined(separator: "\n") + "\n\n" + body
        if chosen.isEmpty, page?.cut == true { text += "\n\n[The middle of a long page was left out]" }
        let found = errors.filter { $0.kind == .error }.suffix(20)
        if !found.isEmpty {
            text += "\n\nErrors on this page:\n" + found.map { "- \(DevCopy.strip($0.message))" }.joined(separator: "\n")
        }
        return text
    }
}

extension Browser {
    func copyForAgent(_ asked: Tab? = nil) {
        guard let tab = asked ?? active, tab.isWeb, let web = tab.built else { return }
        web.evaluateInSearch(CopyForAgent.selection) { [weak self, weak tab] value in
            let picked = value as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                Task { @MainActor in
                    let page = picked.isEmpty ? await AIPage.read(tab) : nil
                    guard let text = CopyForAgent.text(title: tab.title, url: tab.pageAddress, selection: picked, page: page, errors: tab.devLog.errors) else {
                        self.announce("Nothing to copy here")
                        return
                    }
                    CopyForAgent.keep(text)
                    self.announce(picked.isEmpty ? "Page copied for your agent" : "Selection copied for your agent")
                }
            }
        }
    }
}
