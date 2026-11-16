import Foundation
@testable import Search

@MainActor
final class LinearSessionFake {
    static let north: [String: Any] = ["id": "u-north", "organization": ["id": "o-north", "urlKey": "north"]]
    static let acme: [String: Any] = ["id": "u-acme", "organization": ["id": "o-acme", "urlKey": "acme"]]

    var users: [[String: Any]] = [LinearSessionFake.north, LinearSessionFake.acme]
    var refuseReal = false
    var lookups: [URLRequest] = []
    var real: [URLRequest] = []

    static func handles(_ request: URLRequest) -> Bool {
        let url = request.url
        return url?.host() == "client-api.linear.app" || url?.path().contains("/linear-session/") == true
    }

    private func json(_ object: Any, _ status: Int) -> (Data, Int) {
        ((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), status)
    }

    private var noUser: (Data, Int) {
        json(["errors": [["message": "Authentication required, no user context",
                          "extensions": ["type": "authentication error", "code": "AUTHENTICATION_ERROR"]]]], 401)
    }

    func answer(_ request: URLRequest, _ answered: (URLRequest) -> (Data, Int)?) -> (Data, Int)? {
        guard request.value(forHTTPHeaderField: "Cookie")?.isEmpty == false else { return noUser }
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
        if (body["query"] as? String ?? "").contains("availableUsers") {
            lookups.append(request)
            return json(["data": ["availableUsers": ["users": users]]], 200)
        }
        real.append(request)
        let user = request.value(forHTTPHeaderField: "user"), organization = request.value(forHTTPHeaderField: "organization")
        let known = users.contains { $0["id"] as? String == user && ($0["organization"] as? [String: Any])?["id"] as? String == organization }
        guard known, !refuseReal else { return noUser }
        return answered(request)
    }
}
