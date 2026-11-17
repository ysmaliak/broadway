import Foundation

enum NetworkReturn {
    static let waitingFaults: Set<LoadFault> = [.timedOut, .connectionLost, .cannotConnect, .offline, .cannotFindHost, .dnsFailed]

    static func remembers(method: String?, hasBody: Bool, url: URL?) -> Bool {
        guard (method ?? "GET").uppercased() == "GET", !hasBody,
              let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func remembers(_ request: URLRequest) -> Bool {
        remembers(method: request.httpMethod, hasBody: request.httpBody != nil || request.httpBodyStream != nil, url: request.url)
    }

    static func waits(_ fault: LoadFault) -> Bool {
        waitingFaults.contains(fault)
    }

    static func cameBack(since began: Int, returns: Int, available: Bool?) -> Bool {
        available == true && returns > began
    }
}

struct NetworkWait {
    private(set) var request: URLRequest?
    private(set) var began = 0
    private(set) var waiting: URLRequest?
    private(set) var owed = false

    var isWaiting: Bool { waiting != nil }

    mutating func began(_ request: URLRequest?, returns: Int) {
        self.request = request.flatMap { NetworkReturn.remembers($0) ? $0 : nil }
        began = returns
    }

    mutating func redirected(_ request: URLRequest?) {
        guard let request else { return }
        self.request = NetworkReturn.remembers(request) ? request : nil
    }

    mutating func end() {
        waiting = nil
        owed = false
    }

    mutating func failed(_ fault: LoadFault, agent: Bool, returns: Int, available: Bool?, onScreen: Bool) -> URLRequest? {
        guard !agent, NetworkReturn.waits(fault), let request else { return nil }
        waiting = request
        owed = false
        guard NetworkReturn.cameBack(since: began, returns: returns, available: available) else { return nil }
        return returned(onScreen: onScreen)
    }

    mutating func waits(on request: URLRequest, returns: Int) {
        waiting = request
        owed = false
        began = returns
    }

    mutating func returned(onScreen: Bool) -> URLRequest? {
        guard waiting != nil else { return nil }
        guard onScreen else {
            owed = true
            return nil
        }
        return take()
    }

    mutating func cameForward() -> URLRequest? {
        guard owed else { return nil }
        return take()
    }

    private mutating func take() -> URLRequest? {
        let request = waiting
        end()
        return request
    }
}
