import Foundation

enum SignInWindows {
    private static let anywhere: [String] = []

    private static let hosts: [String: [String]] = [
        "accounts.google.com": anywhere,
        "appleid.apple.com": anywhere,
        "login.microsoftonline.com": anywhere,
        "login.live.com": anywhere,
        "login.microsoft.com": anywhere,
        "github.com": ["/login", "/sessions"],
        "www.facebook.com": ["/dialog/", "/login"],
        "m.facebook.com": ["/dialog/", "/login"],
        "api.twitter.com": ["/oauth"],
        "twitter.com": ["/i/oauth2", "/i/flow/login", "/oauth"],
        "api.x.com": ["/oauth"],
        "x.com": ["/i/oauth2", "/i/flow/login", "/oauth"],
        "www.linkedin.com": ["/oauth", "/uas/"],
        "slack.com": ["/oauth", "/openid", "/signin"],
        "www.amazon.com": ["/ap/"],
        "na.account.amazon.com": anywhere,
        "eu.account.amazon.com": anywhere,
        "apac.account.amazon.com": anywhere,
        "www.paypal.com": anywhere,
        "www.sandbox.paypal.com": anywhere,
        "shop.app": anywhere,
        "pay.shopify.com": anywhere,
        "accounts.shopify.com": anywhere,
    ]

    private static let families: [String: [String]] = [
        "okta.com": anywhere,
        "oktapreview.com": anywhere,
        "okta-emea.com": anywhere,
        "auth0.com": anywhere,
        "onelogin.com": anywhere,
        "b2clogin.com": anywhere,
        "ciamlogin.com": anywhere,
        "klarna.com": anywhere,
        "firebaseapp.com": ["/__/auth/"],
    ]

    static func listed(_ url: URL?) -> Bool {
        guard let url = BlockedPopups.openable(url), url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return false }
        let path = url.path().lowercased().replacing(#/^/v\d+(\.\d+)?(?=/)/#, with: "")
        let starts: ([String]) -> Bool = { prefixes in
            prefixes.isEmpty || prefixes.contains { prefix in
                guard path.hasPrefix(prefix) else { return false }
                let rest = path.dropFirst(prefix.count)
                return prefix.hasSuffix("/") || rest.isEmpty || rest.first == "/" || rest.first == "."
            }
        }
        if let paths = hosts[host] { return starts(paths) }
        return families.contains { family, paths in host.hasSuffix("." + family) && starts(paths) }
    }

    static func shaped(_ url: URL?) -> Bool {
        guard let url = BlockedPopups.openable(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let names = Set(items.map { $0.name.lowercased() })
        if names.contains("client_id"), !names.isDisjoint(with: ["redirect_uri", "redirect_url", "response_type"]) { return true }
        if names.contains("wa"), names.contains("wtrealm") { return true }
        return !names.isDisjoint(with: ["samlrequest", "oauth_token"])
    }

    static func looks(_ url: URL?) -> Bool {
        listed(url) || shaped(url)
    }
}
