import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct SecretFieldWordsTests {
    static let plain: [String] = [
        "<label>Token name <input aria-label=\"Token name\"></label>",
        "<input name=\"token_name\">",
        "<input id=\"tokenName\">",
        "<input placeholder=\"Name of the token\">",
        "<input name=\"key-label\">",
        "<input aria-label=\"API key description\">",
        "<input aria-label=\"Secret label\">",
        "<input aria-label=\"Token expiry\">",
        "<input name=\"apiKeyName\">",
        "<input aria-label=\"Token title\">",
        "<input aria-label=\"Secret note\">",
        "<input aria-label=\"Token nickname\">",
        "<input aria-label=\"API key alias\">",
        "<input aria-label=\"Token scope\">",
        "<input aria-label=\"Token expires\">",
        "<input aria-label=\"Token type\">",
        "<input id=\"api-key-expiration\">",
        "<input placeholder=\"Description of this API key\">",
        "<input placeholder=\"Label for the token\">",
        "<input type=\"checkbox\" aria-label=\"Pin to top\">",
        "<input type=\"checkbox\" name=\"pinned\" id=\"pin\">",
        "<button aria-label=\"Pin to top\">Pin</button>",
        "<input aria-label=\"Pin location\">",
        "<input aria-label=\"Pinterest profile\">",
        "<input aria-label=\"Keyword\">",
        "<input name=\"keywords\">",
        "<input aria-label=\"Postcode\">",
        "<input aria-label=\"Zip code\">",
        "<input aria-label=\"Country code\">",
        "<input aria-label=\"Promo code\">",
        "<input aria-label=\"Coupon code\">",
        "<input aria-label=\"Discount code\">",
        "<input aria-label=\"Passenger name\">",
        "<input aria-label=\"Passport number\">",
        "<input aria-label=\"Boarding pass number\">",
        "<input aria-label=\"One-time payment amount\">",
        "<input aria-label=\"Card notes\">",
        "<input name=\"scorecard_notes\">",
        "<input aria-label=\"Email\">",
        "<input autocomplete=\"username\" name=\"user\">",
        "<input aria-label=\"First name\">",
        "<input type=\"search\" aria-label=\"Search\">",
        "<input name=\"lessons\">",
        "<input id=\"className\">",
        "<input aria-label=\"Your opinion\">",
        "<input aria-label=\"Shipping method\">",
        "<textarea aria-label=\"Message\"></textarea>",
        "<input aria-label=\"Phone\">",
        "<input type=\"radio\" name=\"pin_choice\" aria-label=\"Pin\">",
        "<button aria-label=\"Show password\"></button>",
        "<input type=\"submit\" name=\"reset_password\" value=\"Reset password\">",
        "<input aria-label=\"Token amount\">",
        "<input aria-label=\"Secret name\">",
        "<select aria-label=\"Token type\"><option>Read</option></select>",
        "<input aria-label=\"City\">",
        "<input aria-label=\"One time donation\">",
        "<input aria-label=\"Token type\" name=\"tokenType\">",
        "<form id=\"apiTokenForm\" data-t><p>Hello</p></form>",
        "<section id=\"access_token_section\" data-t>Tokens</section>",
    ]

    static let secret: [String] = [
        "<input type=\"password\" aria-label=\"Token name\">",
        "<input autocomplete=\"current-password\" aria-label=\"Field\">",
        "<input autocomplete=\"new-password\">",
        "<input autocomplete=\"one-time-code\">",
        "<input autocomplete=\"cc-number\">",
        "<input autocomplete=\"cc-csc\">",
        "<input autocomplete=\"cc-exp\">",
        "<input autocomplete=\"cc-name\">",
        "<input aria-label=\"Password\">",
        "<input name=\"passwd\">",
        "<input name=\"pwd\">",
        "<input aria-label=\"Passcode\">",
        "<input aria-label=\"Passphrase\">",
        "<input aria-label=\"PIN\">",
        "<input name=\"pin\">",
        "<input aria-label=\"PIN code\">",
        "<input aria-label=\"Card number\">",
        "<input name=\"cardnumber\">",
        "<input name=\"cc_num\">",
        "<input aria-label=\"CVC\">",
        "<input aria-label=\"CVV\">",
        "<input aria-label=\"Security code\">",
        "<input aria-label=\"SSN\">",
        "<input aria-label=\"Social security number\">",
        "<input aria-label=\"API key\">",
        "<input name=\"api_key\">",
        "<input aria-label=\"Token\">",
        "<input name=\"access_token\">",
        "<input aria-label=\"Secret\">",
        "<input name=\"client_secret\">",
        "<input aria-label=\"OTP\">",
        "<input aria-label=\"One-time code\">",
        "<input aria-label=\"Verification code\">",
        "<input aria-label=\"IBAN\">",
        "<input aria-label=\"Routing number\">",
        "<label>Recovery phrase <input></label>",
        "<input aria-label=\"Private key\">",
        "<input aria-label=\"Recovery code\">",
        "<input aria-label=\"Backup code\">",
        "<input placeholder=\"Type your API key\">",
        "<input aria-label=\"Re-type password\">",
        "<input aria-label=\"Retype PIN\">",
        "<input name=\"new_password\">",
        "<input name=\"confirmPassword\">",
        "<input placeholder=\"Enter the verification code\">",
        "<fieldset><legend>Your seed words</legend><input aria-label=\"Word 1\"></fieldset>",
        "<input aria-label=\"Token name\" name=\"token\">",
        "<input aria-label=\"Password hint\">",
        "<input name=\"userPassword\">",
        "<input aria-label=\"Card security code\">",
        "<input aria-label=\"Secret answer\">",
        "<input aria-label=\"Client secret\">",
        "<input aria-label=\"Authentication code\">",
        "<input type=\"hidden\" name=\"auth_token\" value=\"x\">",
        "<input aria-label=\"Secret key\">",
        "<input aria-label=\"Personal access token\">",
        "<input aria-label=\"Two-factor code\">",
        "<input aria-label=\"SMS code\">",
        "<input name=\"passCode\">",
        "<input name=\"passPhrase\">",
        "<input name=\"acc_num\">",
        "<input name=\"user_onetime\">",
        "<input placeholder=\"API key: type or paste\">",
        "<input placeholder=\"Token (type here)\">",
        "<input name=\"card\" id=\"number\">",
        "<code id=\"api-key\" data-t>sk-live</code>",
        "<textarea aria-label=\"Notes\">-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----</textarea>",
    ]

    private func verdicts(_ rows: [String]) async throws -> [Bool] {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let body = rows.enumerated().map { "<div data-row=\($0.offset)>\($0.element)</div>" }.joined()
        web.loadHTMLString("<!doctype html><body>\(body)</body>", baseURL: URL(string: "https://example.com/"))
        let script = PageSelection.secretCheck + """
        var rows = document.querySelectorAll('[data-row]');
        if (rows.length !== count) return null;
        var out = [];
        for (var i = 0; i < rows.length; i++) out.push(broadwaySecret(rows[i].querySelector('[data-t]') || rows[i].querySelector('input,textarea,select,button')) ? 1 : 0);
        return out;
        """
        for _ in 0..<500 {
            if let said = try? await web.callAsyncJavaScript(script, arguments: ["count": rows.count], contentWorld: .page) as? [NSNumber] {
                return said.map(\.boolValue)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the page never answered")
        return []
    }

    @Test func fieldsThatNameOrDescribeASecretAreNotSecret() async throws {
        let said = try await verdicts(Self.plain)

        #expect(said.count == Self.plain.count)
        for (row, secret) in zip(Self.plain, said) {
            #expect(!secret, "\(row)")
        }
    }

    @Test func fieldsThatHoldASecretStaySecret() async throws {
        let said = try await verdicts(Self.secret)

        #expect(said.count == Self.secret.count)
        for (row, secret) in zip(Self.secret, said) {
            #expect(secret, "\(row)")
        }
    }

    @Test func theTableIsLongEnough() {
        #expect(Self.plain.count + Self.secret.count >= 60)
    }
}
