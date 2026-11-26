import WebKit

@MainActor
enum ExtensionGrants {
    static func permissionsKey(_ id: String) -> String { "extensions.askedGranted.\(id)" }
    static func sitesKey(_ id: String) -> String { "extensions.askedSites.\(id)" }

    nonisolated static func site(_ string: String) -> String { string == "<all_urls>" ? "*://*/*" : string }

    static func keep(_ permissions: [WKWebExtension.Permission], sites: [WKWebExtension.MatchPattern], for id: String) {
        add(permissions.map(\.rawValue), to: permissionsKey(id))
        add(sites.map { site($0.string) }, to: sitesKey(id))
    }

    static func letGo(_ permissions: [String], sites: [String], for id: String) {
        drop(permissions, from: permissionsKey(id))
        let gone = Set(sites.map(site))
        drop(Array(gone), from: sitesKey(id))
    }

    static func apply(to context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        let found = context.webExtension
        let named = found.requestedPermissions.union(found.optionalPermissions)
        for name in Store.settings.stringArray(forKey: permissionsKey(id)) ?? [] {
            let permission = WKWebExtension.Permission(rawValue: name)
            if named.contains(permission) { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        }
        let places = found.allRequestedMatchPatterns.union(found.optionalPermissionMatchPatterns)
        for string in Store.settings.stringArray(forKey: sitesKey(id)) ?? [] {
            guard let pattern = try? WKWebExtension.MatchPattern(string: string), !Extensions.withheld(pattern),
                  places.contains(where: { $0.string == string || $0.matchesAllURLs || $0.matches(pattern) }) else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    static func forget(_ id: String) {
        Store.settings.removeObject(forKey: permissionsKey(id))
        Store.settings.removeObject(forKey: sitesKey(id))
    }

    private static func add(_ items: [String], to key: String) {
        guard !items.isEmpty else { return }
        let had = Store.settings.stringArray(forKey: key) ?? []
        Store.settings.set(Array(Set(had + items)).sorted(), forKey: key)
    }

    private static func drop(_ items: [String], from key: String) {
        guard !items.isEmpty, let had = Store.settings.stringArray(forKey: key) else { return }
        let left = had.filter { !items.contains($0) }
        if left.isEmpty { Store.settings.removeObject(forKey: key) } else { Store.settings.set(left, forKey: key) }
    }
}
