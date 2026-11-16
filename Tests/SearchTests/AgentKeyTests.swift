import AppKit
import Testing
@testable import Search

@Suite
struct AgentKeyTests {
    @Test func namedKeysAndLettersTakeModifiers() throws {
        let back = try #require(AgentKey.parse("Shift+Tab"))
        let all = try #require(AgentKey.parse("Meta+a"))
        let plain = try #require(AgentKey.parse("Enter"))

        #expect(back.key == "Tab" && back.shift && back.flags == .shift)
        #expect(all.key == "a" && all.command && all.code == 0)
        #expect(plain.plain && plain.code == 36)
    }

    @Test func unknownKeysAndModifiersAreRefused() {
        #expect(AgentKey.parse("Hyper+q") == nil)
        #expect(AgentKey.parse("F13") == nil)
        #expect(AgentKey.parse("Shift+") == nil)
    }

    @Test func pasteCopyAndCutTouchTheClipboard() throws {
        let combos = try ["Meta+v", "Command+C", "Control+x", "Meta+a", "v"].map { try #require(AgentKey.parse($0)) }

        #expect(combos.map(\.touchesClipboard) == [true, true, true, false, false])
    }

    @Test func fillFindsAFieldByRefOrByItsLabel() {
        let elements: [[String: Any]] = [["ref": "e4", "role": "textbox", "name": "Email"], ["ref": "e5", "role": "textbox", "name": "Email again"],
                                         ["ref": "e6", "role": "combobox", "name": "Country"], ["ref": "e7", "role": "button", "name": "Country help"]]

        let byRef = try? AgentFill.match("@e6", in: elements).get()
        let exact = try? AgentFill.match("email", in: elements).get()
        let partial = try? AgentFill.match("Count", in: elements).get()
        let none = try? AgentFill.match("Phone", in: elements).get()

        #expect(byRef?["ref"] as? String == "e6")
        #expect(exact?["ref"] as? String == "e4")
        #expect(partial?["ref"] as? String == "e6")
        #expect(none == nil)
    }

    @Test func fillReadsYesAndNo() {
        #expect(AgentFill.truthy("on") == true)
        #expect(AgentFill.truthy(false) == false)
        #expect(AgentFill.truthy("maybe") == nil)
    }
}
