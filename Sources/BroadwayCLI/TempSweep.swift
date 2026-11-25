import Foundation

public enum TempSweep {
    public static let made = ["broadway-tiles-", "broadway-pdf-", "broadway-stdin-", "broadway-carried-", "broadway-shot-"]
    public static let commandLine = ["broadway-carried-", "broadway-shot-"]
    public static let age: TimeInterval = 86400

    @discardableResult
    public static func whenDue(_ prefixes: [String], in given: URL? = nil, now: Date = Date()) -> [String]? {
        let files = FileManager.default
        let folder = given ?? Given.root
        let mark = folder.appendingPathComponent("broadway-swept").path
        if let info = try? files.attributesOfItem(atPath: mark) {
            guard info[.type] as? FileAttributeType == .typeRegular, (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
            if let last = info[.modificationDate] as? Date, now.timeIntervalSince(last) < age { return nil }
            try? files.setAttributes([.modificationDate: now], ofItemAtPath: mark)
        } else {
            files.createFile(atPath: mark, contents: Data(), attributes: [.modificationDate: now, .posixPermissions: 0o600])
        }
        return sweep(prefixes, in: folder, now: now)
    }

    @discardableResult
    public static func sweep(_ prefixes: [String] = made, in given: URL? = nil, now: Date = Date()) -> [String] {
        let files = FileManager.default
        let folder = given ?? Given.root
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [String] = []
        for name in names {
            guard let prefix = prefixes.first(where: { name.hasPrefix($0) }), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            let path = folder.appendingPathComponent(name).path
            guard let info = try? files.attributesOfItem(atPath: path), info[.type] as? FileAttributeType == .typeDirectory,
                  (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let changed = info[.modificationDate] as? Date, now.timeIntervalSince(changed) > age else { continue }
            if (try? files.removeItem(atPath: path)) != nil { removed.append(name) }
        }
        return removed
    }
}
