import XCTest
@testable import Wavelength

final class DiagnosticCaptureLevelTests: XCTestCase {
    func testBuildDefaultReadsAndNormalizesInfoPlist() throws {
        for (raw, expected) in [("Debug", DiagnosticCaptureLevel.debug),
                                (" DEBUG \n", .debug), ("trace", .trace),
                                ("unknown", .info), ("", .info)] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("capture-\(UUID().uuidString).bundle")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "capture.\(UUID().uuidString)",
                "WavelengthDiagnosticCaptureDefault": raw
            ], format: .xml, options: 0)
            try data.write(to: directory.appendingPathComponent("Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: directory))
            XCTAssertEqual(DiagnosticCaptureLevel.buildDefault(in: bundle), expected)
        }
    }

    func testBetaDefaultAppliesWithoutSavingAPreference() throws {
        let name = "capture-beta-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults, buildDefault: .debug), .debug)
        XCTAssertNil(defaults.object(forKey: "diagnosticsCaptureLevel"))
        XCTAssertNil(defaults.object(forKey: "diagnosticsDebugCapture"))
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults, buildDefault: .info), .info)

        defaults.set("invalid", forKey: "diagnosticsCaptureLevel")
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults, buildDefault: .debug), .debug)
    }

    func testExplicitAndLegacyPreferencesOverrideBetaDefault() throws {
        let name = "capture-choice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(false, forKey: "diagnosticsDebugCapture")
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults, buildDefault: .debug), .info)
        defaults.set(true, forKey: "diagnosticsDebugCapture")
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults, buildDefault: .debug), .debug)
        for level in DiagnosticCaptureLevel.allCases {
            defaults.set(level.rawValue, forKey: "diagnosticsCaptureLevel")
            XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults, buildDefault: .debug), level)
        }
    }
}
