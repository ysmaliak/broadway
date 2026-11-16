import CryptoKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 || arguments.count == 4,
      let key = Data(base64Encoded: arguments[0]),
      let signature = Data(base64Encoded: arguments[2]),
      var message = FileManager.default.contents(atPath: arguments[1])
else {
    FileHandle.standardError.write(Data("usage: verify.swift <public key, base64> <file> <signature, base64> [length]\n".utf8))
    exit(2)
}
if arguments.count == 4 {
    guard let length = Int(arguments[3]), length >= 0, length <= message.count else { exit(1) }
    message = message.prefix(length)
}
guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { exit(1) }
exit(publicKey.isValidSignature(signature, for: message) ? 0 : 1)
