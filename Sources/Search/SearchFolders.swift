import Foundation

enum SearchFolders {
    private static let quiet: Set<String> = [
        "a", "an", "and", "at", "by", "de", "for", "from", "how", "in", "is", "la", "of", "on", "or", "the", "to", "what", "with",
    ]
    private static let separators: Set<String> = ["-", "–", "—", "|", "·", "•", ":", "/"]

    static func query(of url: URL?, title: String = "", customTemplate: String? = nil) -> String? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path()
        func item(_ name: String) -> String? {
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == name }?.value?
                .replacingOccurrences(of: "+", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func from(_ title: String, ending: String) -> String? {
            guard let cut = title.range(of: ending, options: [.caseInsensitive, .backwards]) else { return nil }
            let words = title[..<cut.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }
        let name = bare.split(separator: ".")
        if name.first == "google", path.hasPrefix("/search") { return item("q") }
        if name.first == "yandex", path.hasPrefix("/search") { return item("text") }
        switch bare {
        case "ya.ru":
            return path.hasPrefix("/search") ? item("text") : nil
        case "duckduckgo.com", "html.duckduckgo.com":
            return item("q")
        case "bing.com", "kagi.com", "ecosia.org", "search.brave.com":
            return path.hasPrefix("/search") || path.hasPrefix("/html") ? item("q") : nil
        case "qwant.com":
            return item("q")
        case "startpage.com":
            return item("query") ?? item("q") ?? (path.hasPrefix("/sp/search") || path.hasPrefix("/do/") ? from(title, ending: " - Startpage") : nil)
        case "perplexity.ai":
            guard path.hasPrefix("/search") else { return nil }
            return item("q") ?? from(title, ending: " - Perplexity") ?? from(title, ending: " | Perplexity")
        default:
            break
        }
        guard let customTemplate, let wanted = template(customTemplate), wanted.host == bare else { return nil }
        return item(wanted.parameter)
    }

    private static func template(_ text: String) -> (host: String, parameter: String)? {
        guard let parts = URLComponents(string: text.replacingOccurrences(of: "%s", with: "broadway-words")),
              let host = parts.host?.lowercased(),
              let item = parts.queryItems?.first(where: { $0.value == "broadway-words" }) else { return nil }
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, item.name)
    }

    static func words(of query: String) -> [String] {
        query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func name(of query: String) -> String {
        AIGroupNames.fromQuery(query) ?? query
    }

    static func related(_ one: String, _ two: String) -> Bool {
        let a = Set(words(of: one)).subtracting(quiet), b = Set(words(of: two)).subtracting(quiet)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.intersection(b).count * 2 >= min(a.count, b.count)
    }

    static func strip(_ title: String, words: [String]) -> String {
        let drop = Set(words)
        func plain(_ token: Substring) -> String {
            token.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        var segments: [[Substring]] = [[]]
        var cuts: [Substring] = []
        for token in title.split(whereSeparator: \.isWhitespace) {
            if separators.contains(String(token)) {
                segments.append([])
                cuts.append(token)
            } else if !drop.contains(plain(token)) {
                segments[segments.count - 1].append(token)
            }
        }
        for index in segments.indices {
            while let first = segments[index].first, quiet.contains(plain(first)) { segments[index].removeFirst() }
            while let last = segments[index].last, quiet.contains(plain(last)) { segments[index].removeLast() }
        }
        var out = ""
        for (index, segment) in segments.enumerated() where !segment.isEmpty {
            if !out.isEmpty { out += " \(cuts[index - 1]) " }
            out += segment.joined(separator: " ")
        }
        return out.isEmpty ? title : out
    }

    static func matchesAll(_ text: String, words: [String]) -> Bool {
        let text = text.lowercased()
        return words.allSatisfy(text.contains)
    }

    static func matches(title: String, address: String, words: [String]) -> Bool {
        let text = (title + " " + address).lowercased()
        return !words.isEmpty && words.allSatisfy(text.contains)
    }
}

extension Browser {
    func searchQuery(of tab: Tab) -> String? {
        SearchFolders.query(of: tab.address, title: tab.title,
                            customTemplate: prefs.engine == .custom ? prefs.customEngine : nil)
    }

    func fileSearchResult(_ tab: Tab, from source: Tab?) {
        quietly { fileSearchResultQuietly(tab, from: source) }
    }

    private func fileSearchResultQuietly(_ tab: Tab, from source: Tab?) {
        guard prefs.usesTabGroups, let source, !source.shy, !source.bench, !tab.shy, !tab.bench, tab.pin == nil else { return }
        let query = searchQuery(of: source)
        if let id = source.groupID, let folder = tabGroups.first(where: { $0.id == id }) {
            guard let held = folder.query else { return }
            if query.map({ $0.caseInsensitiveCompare(held) == .orderedSame || SearchFolders.related(held, $0) }) ?? true {
                if tab.groupID != id { move(tab, toGroup: id) }
                tab.trimWords = SearchFolders.words(of: query ?? held)
                return
            }
        }
        guard source.pin == nil, let query else { return }
        let folder = tabGroups.first { $0.query.map { $0.caseInsensitiveCompare(query) == .orderedSame } == true }
            ?? tabGroups.first { $0.query.map { SearchFolders.related($0, query) } == true }
        let carried = carriesSearch(source) ? [source] : []
        let groups = AIGroups.shared
        if let folder {
            for page in carried + [tab] where page.groupID != folder.id { move(page, toGroup: folder.id) }
        } else if let id = newFolder(with: carried + [tab], named: SearchFolders.name(of: query), editing: false),
                  let index = tabGroups.firstIndex(where: { $0.id == id }) {
            tabGroups[index].query = query
            if groups.active(self) {
                tabGroups[index].ai = true
                groups.grouper(for: self).nameSoon(id)
            }
        }
        tab.trimWords = SearchFolders.words(of: query)
        writeSession(now: true)
    }

    func carriesSearch(_ source: Tab) -> Bool {
        guard source.pin == nil, !source.shy, !source.bench, split(for: source) == nil,
              tabs.contains(where: { $0.id == source.id }) else { return false }
        guard let id = source.groupID else { return true }
        return tabGroups.first { $0.id == id }?.query != nil
    }

    @discardableResult
    func folderFromSearch(_ text: String) -> UUID? {
        let words = SearchFolders.words(of: text)
        let matched = tabs(in: nil).filter { tab in
            !tab.shy && !tab.bench && !tab.isBlank
                && SearchFolders.matches(title: tab.label, address: tab.address?.absoluteString ?? "", words: words)
        }
        guard !matched.isEmpty else {
            announce("No loose tabs match “\(text)”")
            return nil
        }
        guard let id = newFolder(with: matched, named: text, editing: false),
              let index = tabGroups.firstIndex(where: { $0.id == id }) else { return nil }
        tabGroups[index].query = text
        for tab in matched { tab.trimWords = words }
        writeSession(now: true)
        return id
    }

    func askForFolderFromSearch() {
        Ask.name("New Folder from Search", detail: "Loose tabs with these words in their title or address go into a folder named for them",
                 placeholder: "pizza rome", confirm: "Create") { [weak self] in self?.folderFromSearch($0) }
    }
}
