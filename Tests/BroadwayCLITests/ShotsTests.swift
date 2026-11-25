import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(1)))
struct ShotsTests {
    @Test func outIsAnotherNameForOutput() throws {
        let (globals, rest) = try Globals.extract(["shot", "--out", "-", "--tiles"], environment: [:])
        #expect(globals.output == "-")
        #expect(rest == ["shot", "--tiles"])
        #expect(try Globals.extract(["pdf", "-o", "-"], environment: [:]).0.output == "-")
    }

    @Test func aTarHoldsEachFileUnderItsName() {
        var archive = Tar()
        archive.add("tile-01.png", Data(repeating: 7, count: 600), date: Date(timeIntervalSince1970: 0))
        archive.add("tile-02.png", Data([1, 2, 3]), date: Date(timeIntervalSince1970: 0))
        let data = archive.finished()
        #expect(data.count == 512 + 1024 + 512 + 512 + 1024)
        #expect(String(decoding: data.prefix(11), as: UTF8.self) == "tile-01.png")
        #expect(String(decoding: data[124..<135], as: UTF8.self) == "00000001130")
        #expect(String(decoding: data[257..<262], as: UTF8.self) == "ustar")
        let header = Array(data[0..<512])
        var blank = header
        for index in 148..<156 { blank[index] = UInt8(ascii: " ") }
        let sum = blank.reduce(0) { $0 + Int($1) }
        #expect(Int(String(decoding: header[148..<154], as: UTF8.self), radix: 8) == sum)
        #expect(String(decoding: data[(512 + 1024)..<(512 + 1024 + 11)], as: UTF8.self) == "tile-02.png")
        #expect(data.suffix(1024).allSatisfy { $0 == 0 })
    }

    @Test func tileLinesSayWhereEachTileStartsAndWhatIsLeft() {
        let rows: [[String: Any]] = [["tile": 2, "offset": 640, "path": "/t/tile-02.png", "width": 800, "height": 700],
                                     ["tile": 3, "offset": 1280, "unchanged": true, "changed": "0.1%"]]
        let lines = Shots.lines(["total": 9, "from": 2, "to": 3], rows: rows)
        #expect(lines == ["Tiles 2 to 3 of 9, 800 by 700 pixels each", "tile 2 at 640: /t/tile-02.png",
                          "tile 3 at 1280: unchanged since your last shot of it (0.1% of pixels)", "More: broadway shot --tiles --from 4"])
    }
}
