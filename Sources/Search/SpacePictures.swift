import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class SpacePictures {
    typealias Preview = @MainActor (Tab, @escaping (NSImage?) -> Void) -> Void
    typealias Presentation = @MainActor (Tab, @escaping () -> Void) -> Void
    struct Picture {
        let image: NSImage
        let address: URL?
    }
    private(set) var images: [UUID: [Tab.ID: Picture]] = [:]
    private(set) var landings: [UUID: [Tab.ID: Picture]] = [:]
    @ObservationIgnored private var tickets: [UUID: UUID] = [:]
    @ObservationIgnored private let preview: Preview
    @ObservationIgnored private let presentation: Presentation
    @ObservationIgnored private let landingCovers = NSMapTable<Tab, NSImage>.weakToWeakObjects()
    @ObservationIgnored private var follows: [Tab.ID: (space: UUID, ticket: UUID)] = [:]
    @ObservationIgnored private var due: [Tab.ID: DispatchWorkItem] = [:]
    @ObservationIgnored var settle: TimeInterval = 0.6

    init(presentation: Presentation? = nil, preview: Preview? = nil) {
        self.presentation = presentation ?? Self.afterPresentation
        self.preview = preview ?? { tab, done in
            guard tab.failure == nil, let web = tab.built, !web.unpainted, web.bounds.width > 0, web.bounds.height > 0 else { return done(nil) }
            tab.preview(width: web.bounds.width, done)
        }
    }

    func capture(_ space: UUID, tabs: [Tab]) {
        let tabs = tabs.filter { $0.isWeb && !$0.floating }
        images[space] = [:]
        let ticket = UUID()
        tickets[space] = ticket
        for tab in tabs {
            let address = tab.address
            preview(tab) { [weak self, weak tab] image in
                guard let self, self.tickets[space] == ticket, let image, let tab, tab.address == address else { return }
                self.images[space, default: [:]][tab.id] = Picture(image: image, address: address)
            }
        }
    }

    func follow(_ space: UUID, tabs: [Tab]) {
        for tab in tabs where tab.isWeb && !tab.floating && follows[tab.id]?.space != space {
            start(tab, in: space)
        }
    }

    func followPictured(_ space: UUID, tabs: [Tab]) {
        for tab in tabs where tab.isWeb && !tab.floating && follows[tab.id]?.space != space && images[space]?[tab.id] != nil {
            changed(tab, ticket: start(tab, in: space))
        }
    }

    @discardableResult
    private func start(_ tab: Tab, in space: UUID) -> UUID {
        let ticket = UUID()
        follows[tab.id] = (space, ticket)
        track(tab, ticket: ticket)
        return ticket
    }

    func keepFollowing(_ spaces: Set<UUID>) {
        for (id, follow) in follows where !spaces.contains(follow.space) {
            follows[id] = nil
            due.removeValue(forKey: id)?.cancel()
        }
    }

    var following: Set<Tab.ID> { Set(follows.keys) }

    private func track(_ tab: Tab, ticket: UUID) {
        withObservationTracking {
            _ = tab.heading
            _ = tab.address
            _ = tab.loading
        } onChange: { [weak self, weak tab] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let tab, self.follows[tab.id]?.ticket == ticket else { return }
                    self.track(tab, ticket: ticket)
                    self.changed(tab, ticket: ticket)
                }
            }
        }
    }

    private func changed(_ tab: Tab, ticket: UUID) {
        due.removeValue(forKey: tab.id)?.cancel()
        let item = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, let follow = self.follows[tab.id], follow.ticket == ticket, !tab.loading, !tab.floating else { return }
            self.due[tab.id] = nil
            self.recapture(tab, in: follow.space, ticket: ticket)
        }
        due[tab.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: item)
    }

    private func recapture(_ tab: Tab, in space: UUID, ticket: UUID) {
        let address = tab.address
        preview(tab) { [weak self, weak tab] image in
            guard let self, let image, let tab, tab.address == address, self.follows[tab.id]?.ticket == ticket else { return }
            self.images[space, default: [:]][tab.id] = Picture(image: image, address: address)
        }
    }

    func retake(_ tab: Tab, in space: UUID) {
        guard images[space]?[tab.id] != nil else { return }
        let address = tab.address
        preview(tab) { [weak self, weak tab] image in
            guard let self, let image, let tab, tab.address == address, self.images[space]?[tab.id] != nil else { return }
            self.images[space]?[tab.id] = Picture(image: image, address: address)
        }
    }

    func image(for tab: Tab, in space: UUID) -> NSImage? {
        guard tab.isWeb, !tab.floating, tab.failure == nil, let picture = images[space]?[tab.id], picture.address == tab.address else { return nil }
        return picture.image
    }

    func coverForLanding(_ tab: Tab, in space: UUID) {
        guard tab.cover == nil || tab.cover === landingCovers.object(forKey: tab),
              let image = image(for: tab, in: space), let cover = image.copy() as? NSImage else { return }
        landingCovers.setObject(cover, forKey: tab)
        tab.cover(with: cover)
        landings[space, default: [:]][tab.id] = Picture(image: cover, address: tab.address)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak tab] in
            if let tab { self?.finishLanding(tab, in: space, cover: cover) }
        }
        Task { [weak self, weak tab] in
            while let self, let tab, tab.cover === cover {
                if tab.built?.window != nil {
                    self.presentation(tab) { [weak self, weak tab, weak cover] in
                        if let tab, let cover { self?.finishLanding(tab, in: space, cover: cover) }
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func landingImage(for tab: Tab, in space: UUID) -> NSImage? {
        guard tab.isWeb, !tab.floating, let picture = landings[space]?[tab.id],
              picture.address == tab.address, tab.cover === picture.image else { return nil }
        return picture.image
    }

    private func finishLanding(_ tab: Tab, in space: UUID, cover: NSImage) {
        if landings[space]?[tab.id]?.image === cover {
            landings[space]?[tab.id] = nil
            if landings[space]?.isEmpty == true { landings[space] = nil }
        }
        tab.uncover(cover)
    }

    static func afterPresentation(_ tab: Tab, done: @escaping () -> Void) {
        guard let web = tab.built else { return done() }
        web.callAsyncJavaScript("""
        await new Promise(resolve => {
            let first = 0, second = 0;
            const finish = () => {
                cancelAnimationFrame(first);
                cancelAnimationFrame(second);
                clearTimeout(timer);
                resolve();
            };
            const timer = setTimeout(finish, 750);
            first = requestAnimationFrame(() => { second = requestAnimationFrame(finish); });
        });
        """, arguments: [:], in: nil, in: .defaultClient) { [weak web, weak tab, weak cover = tab.cover] _ in
            guard let web, let tab, let cover, tab.cover === cover else { return done() }
            Settling.afterDrawing(web, done)
        }
    }

    func clear() {
        follows = [:]
        due.values.forEach { $0.cancel() }
        due = [:]
        landings = [:]
        tickets = [:]
        images = [:]
    }

    func discard(_ space: UUID) {
        keepFollowing(Set(follows.values.map(\.space)).subtracting([space]))
        landings[space] = nil
        tickets[space] = nil
        images[space] = nil
    }
}
