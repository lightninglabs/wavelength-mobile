import CommonCrypto
import Foundation
import Security

/// Verifies password fallback without reading the biometric-protected secret
/// or restarting an unlocked daemon. The salted verifier contains no wallet key.
struct CredentialVerifier: Codable {
    let salt: Data
    let digest: Data
    let rounds: UInt32

    init(secret: Data) throws {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        self.salt = salt
        rounds = 210_000
        digest = try Self.derive(secret, salt: salt, rounds: rounds)
    }

    func matches(_ secret: Data) throws -> Bool {
        let candidate = try Self.derive(secret, salt: salt, rounds: rounds)
        guard candidate.count == digest.count else { return false }
        return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ secret: Data, salt: Data, rounds: UInt32) throws -> Data {
        var result = Data(count: 32)
        let status = secret.withUnsafeBytes { password in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        password.bindMemory(to: Int8.self).baseAddress, secret.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw NSError(domain: "CredentialVerifier", code: Int(status)) }
        return result
    }
}
