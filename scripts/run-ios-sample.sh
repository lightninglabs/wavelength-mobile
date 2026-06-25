#!/usr/bin/env bash
#
# run-ios-sample.sh builds and runs the iOS sample on a booted simulator,
# entirely from the command line (no Xcode GUI). It:
#   1. stages the Walletdk.xcframework (via fetch-xcframework.sh) if missing,
#   2. generates the Xcode project from project.yml with xcodegen,
#   3. boots a simulator (creating one if none exists),
#   4. builds, installs, and launches the app.
#
# Requires: macOS + Xcode, xcodegen (brew install xcodegen), and an iOS
# simulator runtime (xcodebuild -downloadPlatform iOS).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_DIR="${REPO_ROOT}/ios/Sample"
BUNDLE_ID="engineering.lightning.walletdk.sample"
SCHEME="WalletdkSample"

# 1. Stage the bindings.
if [[ ! -d "${REPO_ROOT}/ios/WalletKit/Frameworks/Walletdk.xcframework" ]]; then
	echo "==> staging Walletdk.xcframework"
	"${REPO_ROOT}/scripts/fetch-xcframework.sh"
fi

# 2. Generate the project.
echo "==> xcodegen generate"
( cd "${SAMPLE_DIR}" && xcodegen generate )

# 3. Pick (or create) and boot a simulator.
device_udid="$(xcrun simctl list devices available | grep -oE 'iPhone[^(]*\([-0-9A-F]+\)' | head -1 | grep -oE '[-0-9A-F]{36}' || true)"
if [[ -z "${device_udid}" ]]; then
	runtime="$(xcrun simctl list runtimes | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS[-0-9]+' | head -1)"
	devtype="$(xcrun simctl list devicetypes | grep -oE 'com.apple.CoreSimulator.SimDeviceType.iPhone[-0-9A-Za-z]+' | head -1)"
	echo "==> creating simulator (${devtype} / ${runtime})"
	device_udid="$(xcrun simctl create "damobile-iphone" "${devtype}" "${runtime}")"
fi
echo "==> booting ${device_udid}"
xcrun simctl bootstatus "${device_udid}" -b || xcrun simctl boot "${device_udid}" || true

# 4. Build, install, launch.
echo "==> xcodebuild"
xcodebuild \
	-project "${SAMPLE_DIR}/${SCHEME}.xcodeproj" \
	-scheme "${SCHEME}" \
	-destination "id=${device_udid}" \
	-derivedDataPath "${SAMPLE_DIR}/DerivedData" \
	build

app="${SAMPLE_DIR}/DerivedData/Build/Products/Debug-iphonesimulator/${SCHEME}.app"
echo "==> installing ${app}"
xcrun simctl install "${device_udid}" "${app}"
xcrun simctl launch "${device_udid}" "${BUNDLE_ID}"

echo "==> running. Screenshot with: xcrun simctl io ${device_udid} screenshot ui.png"
