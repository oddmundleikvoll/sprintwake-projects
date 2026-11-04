import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: verify-update PUBLIC_KEY SIGNATURE ARCHIVE\n", stderr)
    exit(2)
}
guard let keyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let archive = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fputs("invalid update signing data\n", stderr)
    exit(2)
}
guard publicKey.isValidSignature(signature, for: archive) else {
    fputs("invalid Sparkle EdDSA signature\n", stderr)
    exit(1)
}
print("verified")
