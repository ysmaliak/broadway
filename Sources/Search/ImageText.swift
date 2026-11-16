import AppKit
import ImageIO
import Vision
import WebKit

final class ImageText: @unchecked Sendable {
    static let longestEdge = 4096
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false

    enum Failure: Error { case invalidImage }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = request
        lock.unlock()
        current?.cancel()
    }

    static func thumbnail(_ data: Data) throws -> CGImage {
        guard Browser.reasonable(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longestEdge,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { throw Failure.invalidImage }
        return image
    }

    func recognize(_ data: Data) async throws -> [String] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) { try self.read(data) }.value
        } onCancel: {
            self.cancel()
        }
    }

    private func read(_ data: Data) throws -> [String] {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
        let image = try Self.thumbnail(data)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US", "ru-RU"]
        recognition.usesLanguageCorrection = true
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        request = recognition
        lock.unlock()
        defer {
            lock.lock()
            request = nil
            lock.unlock()
        }
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        lock.lock()
        let ended = cancelled
        lock.unlock()
        if ended { throw CancellationError() }
        return (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    @MainActor static var board: NSPasteboard { Store.testing ? testBoard : .general }
    @MainActor private static let testBoard = NSPasteboard(name: .init("com.ysmaliak.broadway.test.image-text.\(getpid())"))
}

extension Browser {
    func copyImageText(at url: URL, in tab: Tab) {
        tab.imageTextTask?.cancel()
        let frame = tab.imageFrame
        let token = UUID()
        tab.imageTextToken = token
        tab.imageTextTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if tab.imageTextToken == token {
                    tab.imageTextTask = nil
                    tab.imageTextToken = nil
                }
            }
            do {
                let loaded = await loadedImageData(at: url, in: tab, frame: frame)
                try Task.checkCancellation()
                let data: Data?
                if let loaded { data = loaded } else { data = await imageData(at: url, in: tab) }
                try Task.checkCancellation()
                guard let data else { throw ImageText.Failure.invalidImage }
                let lines = try await ImageText().recognize(data)
                try Task.checkCancellation()
                guard !lines.isEmpty else { announce("No text found"); return }
                ImageText.board.clearContents()
                ImageText.board.setString(lines.joined(separator: "\n"), forType: .string)
                announce("Copied \(lines.count) \(lines.count == 1 ? "line" : "lines")")
            } catch {
                if !Task.isCancelled { announce("Couldn't read text in that image") }
            }
        }
    }

    private func loadedImageData(at url: URL, in tab: Tab, frame: WKFrameInfo?) async -> Data? {
        guard let web = tab.built else { return nil }
        let script = """
        const image = Array.from(document.images).find(el => el.currentSrc === src && el.complete && el.naturalWidth > 0);
        if (!image) return null;
        const scale = Math.min(1, 4096 / Math.max(image.naturalWidth, image.naturalHeight));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        try {
            const context = canvas.getContext('2d');
            context.fillStyle = 'white';
            context.fillRect(0, 0, canvas.width, canvas.height);
            context.drawImage(image, 0, 0, canvas.width, canvas.height);
            return canvas.toDataURL('image/png').split(',')[1];
        } catch (_) { return null; }
        """
        let value: Any? = await withCheckedContinuation { done in
            web.callAsyncJavaScript(script, arguments: ["src": url.absoluteString], in: frame, in: Web.world) {
                done.resume(returning: try? $0.get())
            }
        }
        return (value as? String).flatMap { Data(base64Encoded: $0) }
    }
}

extension Tab {
    func cancelImageText() {
        imageTextTask?.cancel()
        imageTextTask = nil
        imageTextToken = nil
    }
}
