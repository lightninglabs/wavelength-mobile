#!/usr/bin/env bash
# Use an available iPhone and ad-hoc Simulator signing. Keychain tests require
# an app signature, but CI must not use an Apple account or distribution team.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"
result_root="${repo_root}/.ci-results/ios"
mkdir -p "${result_root}"
xcodegen generate --spec ios/Sample/project.yml
xcrun simctl list devices available --json > "${result_root}/devices.json"
simulator_id="$(python3 - "${result_root}/devices.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    devices = json.load(stream)["devices"]
def version(item):
    return tuple(int(part) for part in item[0].rsplit("iOS-", 1)[-1].split("-") if part.isdigit())

for runtime, values in sorted(devices.items(), key=version, reverse=True):
    if ".iOS-" not in runtime:
        continue
    for device in values:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
raise SystemExit("No available iPhone Simulator runtime")
PY
)"
xcodebuild test \
  -project ios/Sample/Wavelength.xcodeproj -scheme Wavelength \
  -configuration Debug -destination "platform=iOS Simulator,id=${simulator_id}" \
  -destination-timeout 120 -only-testing:WavelengthTests \
  -resultBundlePath "${result_root}/Tests.xcresult" \
  -derivedDataPath "${RUNNER_TEMP:-/tmp}/wavelength-ci-derived-data" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= \
  2>&1 | tee "${result_root}/xcodebuild.log"
