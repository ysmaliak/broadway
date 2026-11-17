import AppKit

@MainActor
enum AnswerBoard {
    static var board: NSPasteboard = Store.testing
        ? NSPasteboard(name: NSPasteboard.Name("com.ysmaliak.broadway.test.answers.\(getpid())"))
        : .general

    static func write(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static var written: String { board.string(forType: .string) ?? "" }
}

extension Browser {
    func addAnswerRow() {
        guard siteChip == nil, fieldPlace == nil, !summoning else { return }
        let question = FieldCurrency.question(typed)
        let answer = FieldAnswers.answer(for: typed) ?? question.flatMap {
            FieldCurrency.answer($0, rates: CurrencyRates.shared.cache.rates)
        }
        if let question, question.from != "RUB", question.to != "RUB",
           CurrencyRates.shared.refreshing || CurrencyRates.shared.cache.due(at: Date()) {
            let asked = typed
            Task { [weak self] in
                let changed = await CurrencyRates.shared.refresh()
                guard changed, let self, self.fieldShowing, self.typed == asked, self.picked == nil,
                      self.siteChip == nil, self.fieldPlace == nil, !self.summoning else { return }
                self.retype()
            }
        }
        guard let answer else { return }
        for index in offers.indices { offers[index].leads = false }
        var row = Suggestion(key: answer.answer, title: answer.expression, url: FieldAction.nowhere, kind: .answer(answer))
        row.leads = true
        offers.insert(row, at: 0)
        ending = nil
    }

    func copyAnswer(_ answer: FieldAnswer, whole: Bool) {
        AnswerBoard.write(whole ? answer.full : answer.copy)
        announce("Copied")
    }

    var leadingAnswer: FieldAnswer? {
        let row = fieldRow.flatMap { offers.indices.contains($0) ? offers[$0] : nil } ?? offers.first
        if case .answer(let answer) = row?.kind, fieldRow != nil || row?.leads == true { return answer }
        return nil
    }
}

final class FieldAnswerRowView: NSView {
    var answer: FieldAnswer { didSet { if answer != oldValue { refresh() } } }
    var copyWhole: ((FieldAnswer) -> Void)?

    private let icon = FieldLine.symbol("equal", size: 13, weight: .medium)
    private let value = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold), color: KitColor.ink)
    private let aside = FieldLine.label("", size: 14, opacity: 0.68)
    private let copy = KitButton(.plain(press: 1), label: "Copy with Question")
    private let copyCap = FieldKeyCap("⌘↩")

    init(answer: FieldAnswer) {
        self.answer = answer
        super.init(frame: .zero)
        copy.content = copyCap
        copy.action = { [weak self] in
            guard let self else { return }
            self.copyWhole?(self.answer)
        }
        for view in [icon, value, aside, copy] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var symbol: String {
        switch answer.kind {
        case .sum: return "equal"
        case .base: return "number"
        case .unit: return "ruler"
        case .time: return "clock"
        case .date: return "calendar"
        case .currency: return "coloncurrencysign"
        }
    }

    private var asideText: String { answer.detail.isEmpty ? answer.expression : answer.detail }

    private func refresh() {
        icon.name = symbol
        value.text = answer.answer
        aside.text = asideText
        copy.kitAccess(help: "Copy “\(answer.full)”")
        setAccessibilityLabel("\(answer.answer), \(asideText)")
        setAccessibilityHelp("Press Return to copy")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let cap = copyCap.intrinsicContentSize
        FieldLine.place([.box(icon, 18, 18), .text(value, priority: 1), .text(aside), .spacer(0), .box(copy, cap.width, max(24, cap.height))],
                        in: self, padding: 10, spacing: 12)
    }
}
