import Foundation
import WebKit

@MainActor
enum ExtensionRequest {
    struct Answer {
        var permissions: Set<WKWebExtension.Permission>
        var sites: Set<String>
        var allowed: Bool
        var at: Date
    }

    static var answered: [String: Answer] = [:]

    static let silent: Set<String> = ["tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
                                      "system.cpu", "system.memory", "system.display", "favicon"]

    static func ask(mine: [String], theirs: [String], sites: [String], gesture: Bool,
                    context: WKWebExtensionContext, owner: Extensions) async throws -> Bool {
        let id = context.uniqueIdentifier
        let found = context.webExtension
        let manifest = found.manifest
        let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
        let wanted = theirs.map { WKWebExtension.Permission(rawValue: $0) }
        let origins = sites.compactMap { try? WKWebExtension.MatchPattern(string: $0) }.filter { !Extensions.withheld($0) }
        let listed = found.requestedPermissions.union(found.optionalPermissions)
        let places = found.allRequestedMatchPatterns.union(found.optionalPermissionMatchPatterns)
        let covered = { (origin: WKWebExtension.MatchPattern) in
            places.contains { $0.string == origin.string || $0.matchesAllURLs || $0.matches(origin) }
        }
        guard mine.allSatisfy(named.contains), wanted.allSatisfy(listed.contains), origins.allSatisfy(covered) else {
            throw ExtensionShims.Unsupported(what: "Only permissions specified in the manifest may be requested.")
        }
        let key = "extensions.granted.\(id)"
        let stored = Store.settings.stringArray(forKey: key) ?? []
        let had = Set(stored).union(manifest["permissions"] as? [String] ?? [])
        let ours = mine.filter { !had.contains($0) }
        let missing = wanted.filter { !held(context.permissionStatus(for: $0)) }
        let unreached = origins.filter { !reached($0, in: context) }
        guard !ours.isEmpty || !missing.isEmpty || !unreached.isEmpty else { return true }
        if !missing.isEmpty || !unreached.isEmpty {
            let when = [Extensions.clicked[id], Extensions.touched[id]].compactMap { $0 }.max()
            guard gesture || when.map({ Date().timeIntervalSince($0) < 10 }) == true else {
                throw ExtensionShims.Unsupported(what: "Invalid call to permissions.request(). Must be called during a user gesture.")
            }
            Extensions.clicked[id] = nil
            Extensions.touched[id] = nil
        }
        let spoken = ours.filter { !silent.contains($0) } + missing.map(\.rawValue)
        if !spoken.isEmpty || !unreached.isEmpty {
            let yes = await owner.ask("asks for more access", detail: words(names: spoken, sites: unreached), context: context)
            answered[id] = Answer(permissions: Set(missing), sites: Set(unreached.map(\.string)), allowed: yes, at: Date())
            guard yes else { return false }
        }
        if !ours.isEmpty { Store.settings.set(Array(Set(stored + ours)).sorted(), forKey: key) }
        for permission in missing { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in unreached { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        Extensions.fence(context)
        let kept = wanted.filter { held(context.permissionStatus(for: $0)) }
        let keptSites = origins.compactMap { try? WKWebExtension.MatchPattern(string: ExtensionGrants.site($0.string)) }
            .filter { held(context.permissionStatus(for: $0)) }
        ExtensionGrants.keep(kept, sites: keptSites, for: id)
        return true
    }

    static func words(names: [String], sites: [WKWebExtension.MatchPattern]) -> String {
        var wants = Extensions.siteSentence(sites).map { [$0] } ?? []
        var seen = Set(wants)
        wants += names.sorted().map(Extensions.sentence(for:)).filter { seen.insert($0).inserted }
        return Extensions.abilities(wants)
    }

    static func recent(_ id: String, permissions: Set<WKWebExtension.Permission> = [], sites: Set<String> = []) -> Bool? {
        guard let last = answered[id], Date().timeIntervalSince(last.at) < 10,
              permissions.isSubset(of: last.permissions), sites.isSubset(of: last.sites) else { return nil }
        return last.allowed
    }

    private static func held(_ status: WKWebExtensionContext.PermissionStatus) -> Bool {
        status == .grantedExplicitly || status == .grantedImplicitly
    }

    private static func reached(_ pattern: WKWebExtension.MatchPattern, in context: WKWebExtensionContext) -> Bool {
        let site = (try? WKWebExtension.MatchPattern(string: ExtensionGrants.site(pattern.string))) ?? pattern
        let status = context.permissionStatus(for: site)
        if held(status) { return true }
        if status == .deniedExplicitly || status == .deniedImplicitly { return false }
        if context.deniedPermissionMatchPatterns.keys.contains(where: { !$0.matchesAllHosts && $0.matches(site) }) { return false }
        return context.currentPermissionMatchPatterns.contains { granted in
            granted.scheme == site.scheme && granted.path == site.path && granted.matches(site)
        }
    }
}
