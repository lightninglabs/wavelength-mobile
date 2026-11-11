#!/usr/bin/env python3
"""Build a device candidate with local publisher configuration; never upload it."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]


def relay_configuration(path):
    """Accept only the public configuration fields understood by the app."""
    config = json.loads(path.read_text())
    required = {"origin", "appAlias", "swapIssuer"}
    if not isinstance(config, dict) or set(config) != required | {"receiptHints"}:
        raise ValueError("relay JSON requires origin, appAlias, swapIssuer and receiptHints")
    if not all(isinstance(config[key], str) for key in required):
        raise ValueError("relay identifiers must be strings")
    origin = urlsplit(config["origin"])
    if (origin.scheme != "https" or not origin.hostname or origin.username or
            origin.password or origin.path not in ("", "/") or "?" in config["origin"] or "#" in config["origin"]):
        raise ValueError("origin must be a fixed HTTPS origin")
    for key in ("appAlias",):
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", config[key]):
            raise ValueError(f"invalid {key}")
    if not re.fullmatch(r"0[23][0-9a-fA-F]{64}", config["swapIssuer"]):
        raise ValueError("swapIssuer must be the trusted service's compressed public key")
    if type(config["receiptHints"]) is not bool:
        raise ValueError("receiptHints must be a JSON boolean")
    # Bundle parsing intentionally uses string values, including this opt-in.
    return {**config, "receiptHints": str(config["receiptHints"]).lower()}


def main():
    """Generate an isolated project and build without provisioning or installation."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new directory outside the source checkout")
    parser.add_argument("--bundle-id", required=True)
    relay = parser.add_mutually_exclusive_group(required=True)
    relay.add_argument("--relay-config", type=Path, help="local JSON; never an APNs key or capability")
    relay.add_argument("--without-relay", action="store_true", help="unsigned compile candidate only")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Release")
    parser.add_argument("--prepare-only", action="store_true", help="generate project and plist without compiling")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id):
        parser.error("bundle-id must be an explicit application identifier")
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("output must be outside the source checkout")
    configuration = relay_configuration(args.relay_config) if args.relay_config else None
    apple_environment = "production" if args.configuration == "Release" else "development"
    output.mkdir(parents=True, exist_ok=False)
    sample = ROOT / "ios/Sample"
    # XcodeGen resolves original relative source/package paths from project-root.
    # Redirect generated plists too, so the ordinary app configuration stays empty.
    spec = {
        "include": [{"path": str(sample / "project.yml"), "relativePaths": False}],
        "targets": {"Wavelength": {
            "info": {"path": str(output / "NotificationInfo.plist")},
            "entitlements": {"path": str(output / "Wavelength.entitlements")},
            "settings": {
                "base": {"PRODUCT_BUNDLE_IDENTIFIER": args.bundle_id,
                         "INFOPLIST_KEY_CFBundleDisplayName": "Wavelength Signet"},
                "configs": {
                    "Debug": {"APNS_ENVIRONMENT": "development", "APP_ATTEST_ENVIRONMENT": "development"},
                    "Release": {"APNS_ENVIRONMENT": "production", "APP_ATTEST_ENVIRONMENT": "production"},
                },
            },
        }},
    }
    spec_path = output / "project.json"
    spec_path.write_text(json.dumps(spec, indent=2) + "\n")
    subprocess.run(["xcodegen", "generate", "--spec", str(spec_path),
                    "--project-root", str(sample), "--project", str(output)], check=True)
    plist_path = output / "NotificationInfo.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    plist["CFBundleDisplayName"] = "Wavelength Signet"
    plist["WavelengthNotificationRelays"] = {"signet": configuration} if configuration else {}
    plist_path.write_bytes(plistlib.dumps(plist))
    provenance = {
        "appSource": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "nativeSource": (ROOT / ".wavelength-ios-version").read_text().strip(),
        "bridgeSHA256": hashlib.sha256((ROOT / "scripts/wavelength-ios-recovery.patch").read_bytes()).hexdigest(),
        "bundleID": args.bundle_id, "network": "signet", "appleEnvironment": apple_environment,
        "relayConfigured": configuration is not None, "signed": False,
        "sourceDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
        "buildCompleted": False,
    }
    manifest = output / "build-manifest.json"
    manifest.write_text(json.dumps(provenance, indent=2) + "\n")
    if args.prepare_only:
        return
    native_environment = {**os.environ, "WAVELENGTH_VERSION": provenance["nativeSource"],
                          "WAVELENGTH_REPO": "lightninglabs/wavelength"}
    subprocess.run([str(ROOT / "scripts/fetch-xcframework.sh"), "--if-needed"],
                   env=native_environment, check=True)
    provenance["nativeArtifactOrigin"] = (
        ROOT / "ios/WalletKit/Frameworks/Wavewalletdk.xcframework/.wavelength-origin"
    ).read_text().strip()
    manifest.write_text(json.dumps(provenance, indent=2) + "\n")
    command = ["xcodebuild", "-project", str(output / "Wavelength.xcodeproj"),
               "-scheme", "Wavelength", "-configuration", args.configuration,
               "-destination", "generic/platform=iOS", "-derivedDataPath", str(output / "DerivedData"),
               "CODE_SIGNING_ALLOWED=NO"]
    # No -allowProvisioningUpdates: this command cannot create portal state.
    with (output / "build.log").open("w") as log:
        subprocess.run(command + ["build"], stdout=log, stderr=subprocess.STDOUT, check=True)
    provenance["buildCompleted"] = True
    manifest.write_text(json.dumps(provenance, indent=2) + "\n")
    print(output / f"DerivedData/Build/Products/{args.configuration}-iphoneos/Wavelength.app")


if __name__ == "__main__":
    main()
