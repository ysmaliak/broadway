import Foundation

@MainActor
enum IntegrationReader {
    static func read(_ folder: LiveFolder, with given: Integrations? = nil) async -> LiveReader.Answer? {
        guard folder.source.service == .linear else { return nil }
        guard let list = LinearAPI.List(address: folder.source.address) else { return .failed }
        return await session(folder, list: list, with: given ?? .shared)
    }

    static func point(_ asks: [LiveTouch.Ask], with given: Integrations? = nil) async -> [LiveItem] {
        let integrations = given ?? .shared
        var found: [LiveItem] = []
        let linear = asks.filter { LinearAPI.identifier(of: $0.key) != nil }
        for space in Set(linear.map(\.space)) {
            let keys = linear.filter { $0.space == space }.map(\.key)
            let workspace = keys.compactMap { URL(string: $0) }.compactMap { LinearAPI.workspace(in: $0.absoluteString) }.first
            let answer = await sessionCall(LinearAPI.pointBody(keys), space: space, workspace: workspace,
                                           cookies: await cookies(space), transport: integrations.transport)
            guard case .answered(let data, let status) = answer, (200..<300).contains(status),
                  let items = LinearAPI.pointItems(from: data, keys: keys) else { continue }
            found += items
        }
        return found
    }

    static var cookies: @MainActor (UUID) async -> [HTTPCookie] = { space in
        await Spaces.store(for: space).httpCookieStore.allCookies()
    }

    static let linearSite = URL(string: "https://linear.app/")!

    enum Session: Equatable {
        case signIn
        case answered(Data, Int)
    }

    private struct Asking: Hashable {
        let space: UUID
        let workspace: String
    }

    private static var askers: [Asking: LinearAPI.SessionUser] = [:]

    static func sessionRequest(_ body: Data, cookies: [HTTPCookie], user: LinearAPI.SessionUser?, endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://linear.app", forHTTPHeaderField: "Origin")
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let user {
            request.setValue(user.id, forHTTPHeaderField: "user")
            request.setValue(user.organization, forHTTPHeaderField: "organization")
        }
        return request
    }

    private static func refused(_ data: Data, _ status: Int) -> Bool {
        status == 401 || status == 403 || LinearAPI.refused(data)
    }

    static func sessionCall(_ body: Data, space: UUID, workspace: String?, cookies all: [HTTPCookie],
                            endpoint: URL? = nil, transport: Integrations.Transport) async -> Session? {
        let mine = LiveReader.cookies(all, for: linearSite)
        guard !mine.isEmpty else { return .signIn }
        let asking = Asking(space: space, workspace: workspace?.lowercased() ?? "")
        return await sessionCall(body, asking: asking, workspace: workspace, cookies: mine,
                                 endpoint: endpoint ?? Integrations.sessionEndpoint(), transport: transport, again: askers[asking] != nil)
    }

    private static func sessionCall(_ body: Data, asking: Asking, workspace: String?, cookies: [HTTPCookie], endpoint: URL,
                                    transport: Integrations.Transport, again: Bool) async -> Session? {
        let user: LinearAPI.SessionUser
        if let known = askers[asking] {
            user = known
        } else {
            guard let (data, status) = await transport(sessionRequest(LinearAPI.usersBody, cookies: cookies, user: nil, endpoint: endpoint)) else {
                return nil
            }
            if refused(data, status) { return .signIn }
            guard (200..<300).contains(status), let users = LinearAPI.users(from: data) else { return .answered(data, status) }
            guard let picked = LinearAPI.pick(users, workspace: workspace) else { return .signIn }
            user = picked
        }
        guard let (data, status) = await transport(sessionRequest(body, cookies: cookies, user: user, endpoint: endpoint)) else { return nil }
        guard refused(data, status) else {
            askers[asking] = user
            return .answered(data, status)
        }
        askers[asking] = nil
        guard again else { return .signIn }
        return await sessionCall(body, asking: asking, workspace: workspace, cookies: cookies, endpoint: endpoint,
                                 transport: transport, again: false)
    }

    static func session(_ folder: LiveFolder, list: LinearAPI.List, with integrations: Integrations) async -> LiveReader.Answer {
        let answer = await sessionCall(LinearAPI.body(for: list), space: folder.space, workspace: LinearAPI.workspace(in: folder.source.address),
                                       cookies: await cookies(folder.space), transport: integrations.transport)
        guard let answer else { return .failed }
        guard case .answered(let data, let status) = answer else { return .signIn }
        guard (200..<300).contains(status), let items = LinearAPI.items(from: data, list: list) else { return .failed }
        return .items(items, nil)
    }
}
