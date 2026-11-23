import CryptoKit
import Foundation

// generate_appcast can exit successfully when SUPublicEDKey and the signing key differ.
// Verify the bytes using the same public key shipped in the application.
let arguments = CommandLine.arguments
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
let keyData = Data(base64Encoded: arguments[2]) ?? Data()
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
for feed in arguments.dropFirst(3) {
    let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: feed))
    let signature = try xml.nodes(forXPath: "/rss/channel/item/enclosure/@sparkle:edSignature").first?.stringValue
    guard let signature, let data = Data(base64Encoded: signature),
          publicKey.isValidSignature(data, for: archive) else {
        FileHandle.standardError.write(Data("Archive signature in \(feed) does not match SPARKLE_PUBLIC_KEY.\n".utf8))
        exit(1)
    }
}
