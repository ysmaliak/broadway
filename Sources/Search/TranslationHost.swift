import AppKit
import SwiftUI
import Translation

enum TranslationHost {
    @MainActor
    static func view(configuration: TranslationSession.Configuration, work: @escaping (TranslationSession) async -> Void) -> NSView {
        NSHostingView(rootView: SessionHost(configuration: configuration, work: work))
    }

    private struct SessionHost: View {
        let configuration: TranslationSession.Configuration
        let work: (TranslationSession) async -> Void

        var body: some View {
            Color.clear.frame(width: 1, height: 1)
                .translationTask(configuration) { session in await work(session) }
        }
    }
}
