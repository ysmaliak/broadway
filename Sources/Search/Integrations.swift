import Foundation

enum IntegrationService: String, CaseIterable, Identifiable, Sendable {
    case gitHub = "github"
    case linear

    var id: String { rawValue }

    var name: String {
        switch self {
        case .gitHub: return "GitHub"
        case .linear: return "Linear"
        }
    }
}

final class IntegrationRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

@MainActor
final class Integrations {
    typealias Transport = @MainActor (URLRequest) async -> (Data, Int)?

    static let shared = Integrations()

    var transport: Transport = { await Integrations.send($0) }

    nonisolated static let rootKey = "integrations.api"

    static func fixture(_ service: IntegrationService, settings: UserDefaults = Store.settings,
                        testing: Bool = Store.testing) -> URL? {
        guard testing, let text = settings.string(forKey: rootKey), let url = URL(string: text),
              let host = url.host()?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host)
        else { return nil }
        return url.appendingPathComponent(service.rawValue)
    }

    static func sessionEndpoint(settings: UserDefaults = Store.settings, testing: Bool = Store.testing) -> URL {
        guard let root = fixture(.linear, settings: settings, testing: testing) else {
            return URL(string: "https://client-api.linear.app/graphql")!
        }
        return root.deletingLastPathComponent().appendingPathComponent("linear-session").appendingPathComponent("graphql")
    }

    static func send(_ request: URLRequest) async -> (Data, Int)? {
        await LiveConditional.send(request, delegate: IntegrationRedirects())
    }
}
