import CryptoKit
import Foundation

let seed = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
let secret = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(seed.base64EncodedString())
print(secret.publicKey.rawRepresentation.base64EncodedString())
