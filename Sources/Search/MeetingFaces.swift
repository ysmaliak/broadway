import AppKit
import Contacts
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

protocol FaceSource: AnyObject, Sendable {
    var name: String { get }
    var ready: Bool { get }
    func photo(for email: String) -> Data?
}

final class ContactFaces: FaceSource, @unchecked Sendable {
    private let store = CNContactStore()
    private let lock = NSLock()

    let name = "contacts"

    var ready: Bool { Self.allowed && Self.chosen }

    static let key = "meetings.faces"
    static var allowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    static var undecided: Bool { CNContactStore.authorizationStatus(for: .contacts) == .notDetermined }
    static var chosen: Bool {
        get { Store.settings.object(forKey: key) as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: key) }
    }
    static var on: Bool { allowed && chosen }

    static func ask() async -> Bool {
        if allowed { return true }
        guard undecided else { return false }
        return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    func photo(for email: String) -> Data? {
        guard ready else { return nil }
        let keys = [CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey, CNContactImageDataKey] as [CNKeyDescriptor]
        let found = lock.withLock {
            (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: email), keysToFetch: keys)) ?? []
        }
        for contact in found {
            if let thumb = contact.thumbnailImageData, !thumb.isEmpty { return thumb }
            if contact.imageDataAvailable, let full = contact.imageData, !full.isEmpty { return full }
        }
        return nil
    }
}

final class FixedFaces: FaceSource, @unchecked Sendable {
    let name = "fixed"
    let ready = true
    private let faces: [String: Data]

    init(_ faces: [String: Data]) {
        self.faces = faces
    }

    func photo(for email: String) -> Data? { faces[email] }
}

@MainActor
final class MeetingFaces {
    static let shared = MeetingFaces(sources: Store.testing ? [] : [ContactFaces()],
                                     folder: Store.testing ? nil : Store.file("faces"))
    nonisolated static let keep: TimeInterval = 7 * 24 * 3600
    nonisolated static let missKeep: TimeInterval = 24 * 3600
    nonisolated static let pixels = 96

    private struct Entry {
        let image: NSImage?
        let at: Date
    }

    var sources: [FaceSource]
    let folder: URL?
    var clock: () -> Date = Date.init
    private var memory: [String: Entry] = [:]
    private var waiting: [String: Task<NSImage?, Never>] = [:]

    init(sources: [FaceSource], folder: URL?) {
        self.sources = sources
        self.folder = folder
    }

    static func key(_ email: String) -> String {
        let plain = email.removingPercentEncoding ?? email
        return plain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var looks: Bool { sources.contains { $0.ready } }

    func cached(_ email: String) -> NSImage? {
        let key = Self.key(email)
        guard !key.isEmpty, looks, let entry = memory[key], fresh(entry) else { return nil }
        return entry.image
    }

    func face(for person: MeetingPerson, then arrive: @escaping (NSImage) -> Void) -> NSImage? {
        let key = Self.key(person.email)
        guard !key.isEmpty, looks else { return nil }
        if let entry = memory[key], fresh(entry) { return entry.image }
        Task { if let image = await photo(for: key) { arrive(image) } }
        return nil
    }

    func photo(for email: String) async -> NSImage? {
        let key = Self.key(email)
        guard !key.isEmpty, looks else { return nil }
        if let entry = memory[key], fresh(entry) { return entry.image }
        if let going = waiting[key] { return await going.value }
        let ready = sources.filter(\.ready)
        let folder = folder
        let now = clock()
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            if let saved = Self.read(key, in: folder, at: now) { return saved }
            var found: Data?
            for source in ready {
                guard let data = source.photo(for: key), let small = Self.shrink(data) else { continue }
                found = small
                break
            }
            Self.write(found, key: key, in: folder)
            return found.flatMap(NSImage.init(data:))
        }
        waiting[key] = task
        let image = await task.value
        waiting[key] = nil
        memory[key] = Entry(image: image, at: now)
        return image
    }

    func forget() {
        memory = [:]
        waiting = [:]
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func seed(_ email: String, _ image: NSImage?) {
        memory[Self.key(email)] = Entry(image: image, at: clock())
    }

    private func fresh(_ entry: Entry) -> Bool {
        clock().timeIntervalSince(entry.at) < (entry.image == nil ? Self.missKeep : Self.keep)
    }

    nonisolated static func file(_ key: String, in folder: URL) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name)
    }

    nonisolated private static func read(_ key: String, in folder: URL?, at now: Date) -> NSImage?? {
        guard let folder else { return nil }
        let url = file(key, in: folder)
        guard let made = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url) else { return nil }
        let age = now.timeIntervalSince(made)
        if data.isEmpty { return age < missKeep ? .some(nil) : nil }
        guard age < keep, let image = NSImage(data: data) else { return nil }
        return .some(image)
    }

    nonisolated private static func write(_ data: Data?, key: String, in folder: URL?) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? (data ?? Data()).write(to: file(key, in: folder), options: .atomic)
    }

    nonisolated static func shrink(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels * 2,
              ] as CFDictionary)
        else { return nil }
        let side = min(thumb.width, thumb.height)
        let square = thumb.cropping(to: CGRect(x: (thumb.width - side) / 2, y: (thumb.height - side) / 2, width: side, height: side)) ?? thumb
        let edge = min(side, pixels)
        guard let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        guard let small = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, small, nil)
        return CGImageDestinationFinalize(target) ? out as Data : nil
    }
}
