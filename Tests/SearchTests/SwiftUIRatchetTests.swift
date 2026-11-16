import Foundation
import Testing

@Suite(.timeLimit(.minutes(5)))
struct SwiftUIRatchetTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func importingSwiftUI() throws -> [String] {
        let sources = root.appendingPathComponent("Sources")
        let pattern = try Regex(#"(?m)^\s*(@\w+\s+)*import\s+((struct|enum|class|protocol|func|var|typealias)\s+)?SwiftUI(\.|\s|$)"#)
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var found: [String] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains(pattern) { found.append(String(url.path.dropFirst(root.path.count + 1))) }
        }
        return found.sorted()
    }

    static func baseline() throws -> Int {
        let text = try String(contentsOf: root.appendingPathComponent("Tests/swiftui-imports.txt"), encoding: .utf8)
        return try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func noMoreFilesImportSwiftUIThanTheBaseline() throws {
        let allowed = try Self.baseline()

        let files = try Self.importingSwiftUI()

        #expect(files.count <= allowed, "\(files.count) files import SwiftUI, the baseline in Tests/swiftui-imports.txt allows \(allowed). New UI is AppKit (Sources/Search/Kit).")
    }

    @Test func onlyTheTranslationHostImportsSwiftUI() throws {
        let files = try Self.importingSwiftUI()

        #expect(files == ["Sources/Search/TranslationHost.swift"], "Only TranslationHost.swift may import SwiftUI: Translation's download prompt comes only from SwiftUI's translationTask. Everything else is AppKit (Sources/Search/Kit).")
    }

    @Test func theKitIsAppKit() throws {
        let kit = try Self.importingSwiftUI().filter { $0.hasPrefix("Sources/Search/Kit/") }

        #expect(kit.isEmpty)
    }

    @Test func modelsAreObservableWithoutCombine() throws {
        let sources = Self.root.appendingPathComponent("Sources")
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var found: [String] = []

        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for word in ["ObservableObject", "@Published", "ObservableObjectPublisher"] where text.contains(word) {
                found.append("\(url.path.dropFirst(Self.root.path.count + 1)): \(word)")
            }
        }

        #expect(found.isEmpty, "Models are plain @Observable: no ObservableObject, @Published or ObservableObjectPublisher in Sources. \(found.sorted())")
    }
}
