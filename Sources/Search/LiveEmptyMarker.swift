import Foundation

struct LiveEmptyMarker: Equatable {
    var selector: String
    var words: String

    static let shown = ".blankslate, [class*=\"blankslate\" i], [data-testid*=\"blankslate\" i], [data-testid*=\"empty\" i], h2, h3, p"

    static func of(_ source: LiveSource) -> LiveEmptyMarker? {
        switch source.kind {
        case .pullRequests, .repository:
            return LiveEmptyMarker(selector: shown,
                                   words: #"No results matched your search|There aren.t any open pull requests|Welcome to pull requests"#)
        case .issues:
            return LiveEmptyMarker(selector: shown, words: #"No results matched your search|There aren.t any open issues|Welcome to issues"#)
        case .notifications:
            return LiveEmptyMarker(selector: shown, words: #"All caught up|No new notifications"#)
        case .feed, .page, .subscriptions, .linear:
            return nil
        }
    }

    static func json(for source: LiveSource) -> String {
        guard let marker = of(source),
              let data = try? JSONSerialization.data(withJSONObject: ["selector": marker.selector, "words": marker.words]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
