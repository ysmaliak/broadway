import AppKit
import Combine

struct NewTabsNotice: Equatable {
    var ids: [Tab.ID] = []

    var newest: Tab.ID? { ids.last }

    var text: String { ids.count == 1 ? "New tab opened" : "\(ids.count) new tabs opened" }

    func adding(_ id: Tab.ID) -> NewTabsNotice {
        var made = self
        made.ids.removeAll { $0 == id }
        made.ids.append(id)
        return made
    }

    func kept(in present: [Tab.ID], active: Tab.ID?) -> NewTabsNotice? {
        if let active, ids.contains(active) { return nil }
        let here = Set(present)
        let left = ids.filter(here.contains)
        return left.isEmpty ? nil : NewTabsNotice(ids: left)
    }
}

extension Browser {
    var sideHidden: Bool { folded && !peeking && !isPopup }

    var newTabsShown: NewTabsNotice? {
        guard sideHidden else { return nil }
        return newTabs?.kept(in: tabs.map(\.id), active: activeID)
    }

    func openedBehind(_ tab: Tab) {
        guard window != nil, !tab.agent, !tab.bench else { return }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab else { return }
            noticeOpenedBehind(tab)
        }
    }

    func noticeOpenedBehind(_ tab: Tab) {
        guard sideHidden, !tab.agent, !tab.bench, activeID != tab.id, tabs.contains(where: { $0.id == tab.id }),
              split(for: tab) == nil else { return }
        newTabs = (newTabsShown ?? NewTabsNotice()).adding(tab.id)
        let view = newTabsHush?.view
        newTabsHush?.cancel()
        let clock = NoticeClock(.note, window: { [weak self] in self?.window }) { [weak self] in self?.dropNewTabs() }
        clock.view = view
        newTabsHush = clock
        if newTabsWatch == nil {
            newTabsWatch = kitObserve(initial: false, distinct: true, { [weak self] in self?.newTabsShown == nil }) { [weak self] gone in
                if gone { self?.dropNewTabs() }
            }
        }
    }

    func showNewTabs() {
        guard let id = newTabsShown?.newest, let tab = tabs.first(where: { $0.id == id }) else { return dropNewTabs() }
        dropNewTabs()
        select(tab)
    }

    func dropNewTabs() {
        newTabsHush?.cancel()
        newTabsHush = nil
        newTabsWatch = nil
        if newTabs != nil { newTabs = nil }
    }
}

@MainActor
final class NewTabsNoticeView {
    let note = CapsuleNote("", size: 12, trailing: "Show")
    private weak var browser: Browser?

    init(browser: Browser) {
        self.browser = browser
        note.identifier = NSUserInterfaceItemIdentifier("newtabs.notice")
        note.onPress = { [weak browser] in browser?.showNewTabs() }
        note.setAccessibilityElement(true)
        note.setAccessibilityRole(.button)
    }

    var shown: NewTabsNotice? { browser?.newTabsShown }

    func sync() {
        guard let text = shown?.text else { return }
        if note.label.text != text, !note.label.text.isEmpty, note.superview != nil, note.layer?.animation(forKey: "arrive") == nil {
            NoticeMotion.change(note)
        }
        note.label.text = text
        note.setAccessibilityLabel(text)
        note.invalidateIntrinsicContentSize()
        note.needsLayout = true
    }
}
