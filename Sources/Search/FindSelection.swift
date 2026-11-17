import AppKit
import WebKit

@MainActor
enum FindBoard {
    static var board: NSPasteboard { Store.testing ? testBoard : NSPasteboard(name: .find) }

    private static let testBoard = NSPasteboard(name: NSPasteboard.Name("com.ysmaliak.broadway.test.find.\(getpid())"))

    static func words(_ selection: String) -> String? {
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    static func write(_ words: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(words, forType: .string)
    }
}

extension Browser {
    var canUseSelectionForFind: Bool { active?.isWeb == true }

    var canFindAgain: Bool { finding || (canUseSelectionForFind && !needle.isEmpty) }

    func useSelectionForFind() {
        guard canUseSelectionForFind, let tab = active, let web = tab.built else { return }
        web.evaluateJavaScript(PageView.selected, in: nil, in: .defaultClient) { [weak self, weak tab] result in
            guard let self, let tab, self.active === tab else { return }
            self.takeForFind((try? result.get()) as? String ?? "", board: FindBoard.board)
        }
    }

    func takeForFind(_ selection: String, board: NSPasteboard) {
        guard let words = FindBoard.words(selection) else { return }
        resettingFind = true
        needle = words
        resettingFind = false
        FindBoard.write(words, to: board)
    }
}
