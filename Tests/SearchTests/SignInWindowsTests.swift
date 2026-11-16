import Foundation
import Testing
@testable import Search

struct SignInWindowsTests {
    private func url(_ text: String) -> URL? { URL(string: text) }

    @Test func theProvidersPeopleSignInWithAreListed() {
        let addresses = [
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=x",
            "https://accounts.google.com/gsi/select?client_id=x&ux_mode=popup",
            "https://appleid.apple.com/auth/authorize?client_id=x",
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x",
            "https://login.live.com/oauth20_authorize.srf",
            "https://github.com/login/oauth/authorize?client_id=x",
            "https://github.com/login",
            "https://github.com/sessions/two-factor",
            "https://www.facebook.com/login.php?skip_api_login=1",
            "https://www.facebook.com/v19.0/dialog/oauth?client_id=x",
            "https://www.facebook.com/dialog/oauth?client_id=x",
            "https://api.twitter.com/oauth/authenticate?oauth_token=x",
            "https://x.com/i/oauth2/authorize?client_id=x",
            "https://www.linkedin.com/oauth/v2/authorization?client_id=x",
            "https://slack.com/openid/connect/authorize?client_id=x",
            "https://www.amazon.com/ap/oa?client_id=x",
            "https://dev-12345.okta.com/oauth2/v1/authorize",
            "https://tenant.eu.auth0.com/authorize",
            "https://company.onelogin.com/oidc/2/auth",
            "https://tenant.b2clogin.com/tenant.onmicrosoft.com/oauth2/v2.0/authorize",
            "https://www.paypal.com/checkoutnow?token=x",
            "https://pay.klarna.com/eu/hpp/payments/x",
            "https://shop.app/pay/authentication/login",
            "https://fir-ui-demo-84a6c.firebaseapp.com/__/auth/handler?apiKey=x",
        ]

        for address in addresses {
            #expect(SignInWindows.listed(url(address)), "\(address)")
        }
    }

    @Test func aListedHostsOtherPagesAndItsLookalikesAreNot() {
        let addresses = [
            "https://github.com/someone/project",
            "https://github.com/login-anything/project",
            "https://github.com/loginpage",
            "https://slack.com/signin-tips",
            "https://www.linkedin.com/oauthful",
            "https://www.facebook.com/somepage",
            "https://x.com/someone/status/1",
            "https://www.amazon.com/dp/B000",
            "https://slack.com/pricing",
            "https://accounts.google.com.ads.test/o/oauth2/auth",
            "https://notokta.com/login",
            "https://okta.com.ads.test/",
            "http://accounts.google.com/o/oauth2/auth",
            "https://project.firebaseapp.com/landing",
            "about:blank",
        ]

        for address in addresses {
            #expect(!SignInWindows.listed(url(address)), "\(address)")
        }
        #expect(!SignInWindows.listed(nil))
    }

    @Test func aSignInRequestIsKnownByItsShapeOnAnyHost() {
        #expect(SignInWindows.shaped(url("https://sso.company.example/oauth2/authorize?client_id=x&redirect_uri=https%3A%2F%2Fa.example%2Fcb&response_type=code")))
        #expect(SignInWindows.shaped(url("https://idp.company.example/saml/sso?SAMLRequest=abc&RelayState=x")))
        #expect(SignInWindows.shaped(url("https://sts.company.example/adfs/ls/?wa=wsignin1.0&wtrealm=urn%3Aapp")))
        #expect(SignInWindows.shaped(url("https://api.service.example/oauth/authenticate?oauth_token=x")))
        #expect(!SignInWindows.shaped(url("https://ads.test/landing?client_id=x")))
        #expect(!SignInWindows.shaped(url("https://ads.test/landing?zone=1&redirect_uri=x")))
        #expect(!SignInWindows.shaped(url("about:blank")))
        #expect(SignInWindows.looks(url("https://accounts.google.com/gsi/select")))
        #expect(!SignInWindows.looks(url("https://ads.test/landing")))
    }
}
