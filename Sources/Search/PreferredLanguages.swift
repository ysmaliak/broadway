import Foundation
import Observation
import ObjectiveC
import WebKit

@MainActor
@Observable
final class LanguagePrefs {
    static let shared = LanguagePrefs()

    @ObservationIgnored private let store: UserDefaults

    var chosen: [String]? {
        didSet {
            guard chosen != oldValue else { return }
            if let chosen, !chosen.isEmpty {
                store.set(chosen, forKey: PreferredLanguages.key)
            } else {
                if chosen != nil { chosen = nil }
                store.removeObject(forKey: PreferredLanguages.key)
            }
        }
    }

    init(store: UserDefaults = Store.settings) {
        self.store = store
        chosen = PreferredLanguages.saved(in: store)
    }

    var list: [String] { PreferredLanguages.list(chosen: chosen, mac: PreferredLanguages.mac, space: nil, spaces: false, shy: false) }

    var waitsForRelaunch: Bool { list.first != PreferredLanguages.native.first }
}

enum PreferredLanguages {
    static let key = "languages"

    static var mac: [String] { Locale.preferredLanguages }

    nonisolated(unsafe) private(set) static var launched: [String]?
    nonisolated(unsafe) private static var held: [WKProcessPool] = []

    static var native: [String] { launched ?? mac }

    static func saved(in store: UserDefaults = Store.settings) -> [String]? {
        guard let list = store.stringArray(forKey: key), !list.isEmpty else { return nil }
        return list
    }

    static var settings: [String] { list(chosen: saved(), mac: mac, space: nil, spaces: false, shy: false) }

    static func list(chosen: [String]?, mac: [String], space: [String]?, spaces: Bool, shy: Bool) -> [String] {
        if !shy, spaces, let space, !space.isEmpty { return space }
        if let chosen, !chosen.isEmpty { return chosen }
        return mac.isEmpty ? ["en"] : mac
    }

    @MainActor static func list(for space: UUID?, shy: Bool) -> [String] {
        let own = space.flatMap { Spaces.known[$0]?.languages }
        return list(chosen: LanguagePrefs.shared.chosen, mac: mac, space: own, spaces: Store.settings.bool(forKey: "spaces"), shy: shy)
    }

    static func reader(_ list: [String]) -> Locale.Language {
        Locale.Language(identifier: list.first ?? "en")
    }

    static func reads(_ language: Locale.Language, in list: [String]) -> Bool {
        list.contains { PageTranslator.same(language, Locale.Language(identifier: $0)) }
    }

    static func summary(chosen: [String]?, mac: [String]) -> String {
        guard let chosen, !chosen.isEmpty else { return "Same as your Mac, \(short(mac.first ?? "en"))" }
        let names = chosen.map(short)
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }

    static func names(_ list: [String]) -> String {
        list.map(short).joined(separator: ", ")
    }

    static func short(_ code: String) -> String {
        let parts = Locale.Language.Components(identifier: code)
        guard let base = parts.languageCode?.identifier else { return PageTranslator.name(code) }
        if let script = parts.script?.identifier, base == "zh" || base == "sr" { return PageTranslator.name(base + "-" + script) }
        return PageTranslator.name(base)
    }

    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? PageTranslator.name(code)
    }

    static func ownName(_ code: String) -> String? {
        let own = Locale(identifier: code).localizedString(forIdentifier: code)
        guard let own, own != name(code) else { return nil }
        return own
    }

    static func canonical(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let parts = Locale.Language.Components(identifier: text)
        guard let base = parts.languageCode, base.isISOLanguage,
              Locale(identifier: "en").localizedString(forLanguageCode: base.identifier) != nil else { return nil }
        return [base.identifier, parts.script?.identifier, parts.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    static func parse(_ text: String) -> [String]?? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["mac", "system", "default"].contains(trimmed.lowercased()) { return .some(nil) }
        var out: [String] = []
        for part in trimmed.split(separator: ",") {
            guard let code = canonical(String(part)) else { return nil }
            if !out.contains(code) { out.append(code) }
        }
        return out.isEmpty ? nil : .some(out)
    }

    static let regional: [String: [String]] = [
        "en": ["en-US", "en-GB"], "es": ["es-ES", "es-419"], "pt": ["pt-BR", "pt-PT"],
        "zh": ["zh-Hans", "zh-Hant"], "fr": ["fr-FR", "fr-CA"],
    ]

    static let choices: [String] = {
        let english = Locale(identifier: "en")
        var codes: [String] = []
        for code in Locale.LanguageCode.isoLanguageCodes {
            let id = code.identifier
            guard let named = english.localizedString(forLanguageCode: id), named.lowercased() != id else { continue }
            if id.count > 2, let short = Locale.Language(identifier: id).languageCode?.identifier, short != id, short.count == 2 { continue }
            codes.append(id)
            codes += regional[id] ?? []
        }
        var seen = Set<String>()
        let unique = codes.filter { seen.insert($0).inserted }
        let named = unique.map { ($0, name($0)) }
        var names = Set<String>()
        return named.filter { names.insert($0.1).inserted }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }.map(\.0)
    }()

    static func choices(leaving listed: [String], matching typed: String = "") -> [String] {
        let words = typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return choices.filter { code in
            guard !listed.contains(code) else { return false }
            guard !words.isEmpty else { return true }
            let hay = [code, name(code), ownName(code) ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    static func script(for list: [String], native: [String] = native) -> WKUserScript? {
        guard !list.isEmpty, list != native else { return nil }
        return WKUserScript(source: source(list), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static func source(_ list: [String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
          const list = Object.freeze(\(json));
          const define = (name, value) => {
            try { Object.defineProperty(Navigator.prototype, name, { get() { return value; }, configurable: true, enumerable: true }); } catch (e) {}
          };
          define('languages', list);
          define('language', list[0]);
        })();
        """
    }

    static func launchPool() -> WKProcessPool {
        let chosen = saved()
        launched = chosen
        return pool(chosen)
    }

    @discardableResult
    static func override(_ list: [String]?) -> WKProcessPool {
        let made = pool(list ?? [])
        held.append(made)
        launched = list
        return made
    }

    private typealias SetLanguages = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
    private typealias MakeString = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
    private typealias MakeArray = @convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>, Int) -> UnsafeRawPointer?
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void

    private struct Calls {
        let set: SetLanguages
        let string: MakeString
        let array: MakeArray
        let release: Release?
    }

    private static let calls: Calls? = {
        guard let kit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW | RTLD_NOLOAD) ?? dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW),
              let set = dlsym(kit, "WKContextConfigurationSetOverrideLanguages"),
              let string = dlsym(kit, "WKStringCreateWithUTF8CString"),
              let array = dlsym(kit, "WKArrayCreateAdoptingValues") else { return nil }
        return Calls(set: unsafeBitCast(set, to: SetLanguages.self), string: unsafeBitCast(string, to: MakeString.self),
                     array: unsafeBitCast(array, to: MakeArray.self),
                     release: dlsym(kit, "WKRelease").map { unsafeBitCast($0, to: Release.self) })
    }()

    static var canOverride: Bool {
        calls != nil && NSClassFromString("_WKProcessPoolConfiguration") != nil
            && WKProcessPool.instancesRespond(to: NSSelectorFromString("_initWithConfiguration:"))
    }

    static func pool(_ list: [String]?) -> WKProcessPool {
        guard let list, canOverride, let calls, let kind = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type,
              let ivar = class_getInstanceVariable(kind, "_processPoolConfiguration") else { return WKProcessPool() }
        let configuration = kind.init()
        let ref = Unmanaged.passUnretained(configuration).toOpaque() + ivar_getOffset(ivar)
        var values: [UnsafeRawPointer?] = list.compactMap { code in code.withCString { calls.string($0) } }
        guard values.count == list.count, let array = values.withUnsafeMutableBufferPointer({ calls.array($0.baseAddress!, $0.count) }) else {
            return WKProcessPool()
        }
        calls.set(ref, array)
        calls.release?(array)
        guard let allocated = (WKProcessPool.self as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let made = allocated.perform(NSSelectorFromString("_initWithConfiguration:"), with: configuration)?.takeUnretainedValue() as? WKProcessPool
        else { return WKProcessPool() }
        return made
    }
}
