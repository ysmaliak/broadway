import Foundation
import Testing
@testable import Search

@MainActor
final class HookLab {
    let folder: URL
    let home: URL
    let book: HookBook
    private let keptHome: URL

    init(_ name: String = "lab") throws {
        folder = Store.folder.appendingPathComponent("hook-lab-\(name)-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        home = folder.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        book = HookBook(file: folder.appendingPathComponent("hooks.json"))
        keptHome = HookGate.home
        HookGate.home = home
        HookGate.forgetAsked()
    }

    func close() {
        HookGate.home = keptHome
        HookGate.forgetAsked()
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    func program(_ name: String, _ body: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    func path(_ name: String) -> String { folder.appendingPathComponent(name).path }

    func read(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    @discardableResult
    func add(_ event: HookEvent, _ program: URL, minutes: Int = 15) throws -> Hook {
        try #require(book.add(event, program: program, minutes: minutes))
    }

    func ask<Answer>(_ event: HookEvent, _ fields: [String: Any] = [:], scene: HookScene? = .outside,
                     read: @escaping ([String: Any]) -> HookReading<Answer>) async -> Answer? {
        await withCheckedContinuation { finished in
            HookGate.ask(event, fields, scene: scene, book: book, read: read) { finished.resume(returning: $0) }
        }
    }

    func permission(_ site: String = "https://meet.example.com", wants: [String] = ["camera"], scene: HookScene? = .outside) async -> Bool? {
        await withCheckedContinuation { finished in
            HookAsk.permission(site: site, wants: wants, scene: scene, book: book) { finished.resume(returning: $0) }
        }
    }

    func json(_ name: String) -> [String: Any]? {
        guard let text = read(name) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func anything(_ object: [String: Any]) -> HookReading<String> {
        .answer(object["say"] as? String ?? "")
    }
}

@MainActor
func hookSoon(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}
