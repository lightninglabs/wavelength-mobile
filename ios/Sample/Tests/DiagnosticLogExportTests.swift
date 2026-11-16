import XCTest
@testable import Wavelength

final class DiagnosticLogExportTests: XCTestCase {
    func testFilesPreserveUnicodeAndZIPIsAnAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "2026-11-16T10:00:00.123Z INFO App Árvíztűrő 🌊\n", count: 20_000)
        let files = try DiagnosticLogFiles.prepare(text: text, network: "signet", root: root)
        XCTAssertEqual(try String(contentsOf: files.text, encoding: .utf8), text)
        XCTAssertEqual(files.textSize, Int64(text.utf8.count))
        XCTAssertTrue(files.text.lastPathComponent.hasPrefix("wavelength-signet-"))
        XCTAssertEqual(files.zip.pathExtension, "zip")
        XCTAssertEqual(try Data(contentsOf: files.zip).prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        XCTAssertLessThan(files.zipSize, files.textSize)
        let attachment = XCTAttachment(contentsOfFile: files.zip)
        attachment.name = "log-export-roundtrip.zip"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNewExportDoesNotOverwriteAnExistingAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try DiagnosticLogFiles.prepare(text: "first", network: "mainnet", root: root)
        let second = try DiagnosticLogFiles.prepare(text: "second", network: "testnet", root: root)
        XCTAssertNotEqual(first.zip, second.zip)
        XCTAssertEqual(try String(contentsOf: first.text, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second.text, encoding: .utf8), "second")
    }

    func testPreparationReportsUnwritableDestination() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("occupied".utf8).write(to: file)
        XCTAssertThrowsError(try DiagnosticLogFiles.prepare(text: "logs", network: "signet", root: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "occupied")
    }
}
