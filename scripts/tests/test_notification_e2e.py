"""Check the publisher input boundary and actual XcodeGen plist isolation."""

import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "build-ios-notification-e2e.py"
SPEC = importlib.util.spec_from_file_location("notification_build", SCRIPT)
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class NotificationBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = {
            "origin": "https://relay.example.invalid",
            "appAlias": "wallet-testflight",
            "swapIssuer": "02" + "11" * 32, "receiptHints": True,
        }

    def write_config(self):
        path = self.root / "publisher.json"
        path.write_text(json.dumps(self.config))
        return path

    def test_rejects_destination_changes_and_credentials(self):
        for origin in ["http://relay.example.invalid", "https://user:pass@relay.example.invalid",
                       "https://relay.example.invalid/v1", "https://relay.example.invalid?",
                       "https://relay.example.invalid#fragment"]:
            with self.subTest(origin=origin):
                self.config["origin"] = origin
                with self.assertRaises(ValueError):
                    BUILD.relay_configuration(self.write_config())

    def test_rejects_secret_and_invalid_issuer_or_consent(self):
        original = self.config.copy()
        for changes in [{"providerKey": "secret"}, {"swapIssuer": ""},
                        {"receiptHints": "true"}, {"receiptHints": 1}]:
            with self.subTest(changes=changes):
                self.config = {**original, **changes}
                with self.assertRaises(ValueError):
                    BUILD.relay_configuration(self.write_config())

    def test_generated_release_and_debug_configs_leave_source_empty(self):
        source_plist = BUILD.ROOT / "ios/Sample/NotificationInfo.plist"
        source_before = source_plist.read_bytes()
        for configuration, environment in [("Release", "production"), ("Debug", "development")]:
            with self.subTest(configuration=configuration):
                output = self.root / configuration
                subprocess.run(["python3", str(SCRIPT), "--output", str(output),
                                "--bundle-id", "com.example.wallet", "--configuration", configuration,
                                "--relay-config", str(self.write_config()), "--prepare-only"],
                               check=True, capture_output=True)
                info = plistlib.loads((output / "NotificationInfo.plist").read_bytes())
                self.assertEqual(info["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)")
                self.assertEqual(info["CFBundleShortVersionString"], "$(MARKETING_VERSION)")
                self.assertEqual(info["WavelengthNotificationRelays"], {
                    "signet": {**self.config, "receiptHints": "true"},
                })
                manifest = json.loads((output / "build-manifest.json").read_text())
                self.assertEqual(manifest["appleEnvironment"], environment)
                self.assertFalse(manifest["buildCompleted"])
                self.assertFalse(manifest["signed"])
                project = json.loads(subprocess.check_output([
                    "plutil", "-convert", "json", "-o", "-",
                    str(output / "Wavelength.xcodeproj/project.pbxproj"),
                ]))
                objects = project["objects"]
                target = next(value for value in objects.values()
                              if value.get("isa") == "PBXNativeTarget" and value["name"] == "Wavelength")
                configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
                for identifier in configurations:
                    item = objects[identifier]
                    settings = item["buildSettings"]
                    expected = "production" if item["name"] == "Release" else "development"
                    self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.wallet")
                    self.assertEqual(settings["APNS_ENVIRONMENT"], expected)
                    self.assertEqual(settings["APP_ATTEST_ENVIRONMENT"], expected)
                    self.assertFalse(any(key.startswith("INFOPLIST_KEY_") for key in settings))
        self.assertEqual(source_plist.read_bytes(), source_before)


if __name__ == "__main__":
    unittest.main()
