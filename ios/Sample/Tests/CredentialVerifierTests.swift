import XCTest
@testable import Wavelength

final class CredentialVerifierTests: XCTestCase {
    func testPasswordVerifierSurvivesStorageWithoutKeepingThePassword() throws {
        let password = Data("test-only wallet password".utf8)
        let verifier = try CredentialVerifier(secret: password)
        let saved = try JSONEncoder().encode(verifier)
        let restored = try JSONDecoder().decode(CredentialVerifier.self, from: saved)
        XCTAssertTrue(try restored.matches(password))
        XCTAssertFalse(try restored.matches(Data("wrong password".utf8)))
        XCTAssertNotEqual(verifier.digest, password)
        XCTAssertNotEqual(try CredentialVerifier(secret: password).salt, verifier.salt)
    }
}
