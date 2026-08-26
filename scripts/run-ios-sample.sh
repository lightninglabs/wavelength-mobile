#!/usr/bin/env bash
#
# run-ios-sample.sh builds and runs the iOS sample on a booted simulator,
# entirely from the command line (no Xcode GUI). It:
#   1. stages the Wavewalletdk.xcframework (via fetch-xcframework.sh) if missing,
#   2. generates the Xcode project from project.yml with xcodegen,
#   3. boots a simulator (creating one if none exists),
#   4. builds, installs, and launches the app.
#
# Requires: macOS + Xcode, xcodegen (brew install xcodegen), and an iOS
# simulator runtime (xcodebuild -downloadPlatform iOS).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_DIR="${REPO_ROOT}/ios/Sample"
BUNDLE_ID="engineering.lightning.wavelength.wallet"
SCHEME="Wavelength"

# 1. Stage the bindings.
if [[ ! -d "${REPO_ROOT}/ios/WalletKit/Frameworks/Wavewalletdk.xcframework" ]]; then
	echo "==> staging Wavewalletdk.xcframework"
	"${REPO_ROOT}/scripts/fetch-xcframework.sh"
fi

# 2. Generate the project.
echo "==> xcodegen generate"
( cd "${SAMPLE_DIR}" && xcodegen generate )

# 3. Pick (or create) and boot a simulator.
device_udid="$("${REPO_ROOT}/scripts/select-ios-simulator.sh")"
echo "==> using simulator ${device_udid}"

# `simctl boot` starts the virtual device but intentionally does not show the
# macOS Simulator window. Interactive run targets should open and foreground
# the GUI; set OPEN_SIMULATOR=0 when a headless launch is preferable.
if [[ "${OPEN_SIMULATOR:-1}" == "1" ]]; then
	echo "==> opening Simulator.app"
	open -a Simulator --args -CurrentDeviceUDID "${device_udid}"
fi

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

# simctl only forwards environment variables carrying its SIMCTL_CHILD_
# prefix. Keep normal launches clean, while allowing an external regtest
# environment to configure the app without modifying persisted app settings.
for name in \
	WAVELENGTH_REGTEST \
	WAVELENGTH_AUTOCREATE \
	WAVELENGTH_OPERATOR_ADDRESS \
	WAVELENGTH_SWAP_ADDRESS \
	WAVELENGTH_ESPLORA_URL
do
	if [[ -n "${!name:-}" ]]; then
		export "SIMCTL_CHILD_${name}=${!name}"
	fi
done
xcrun simctl launch "${device_udid}" "${BUNDLE_ID}"

if [[ "${OPEN_SIMULATOR:-1}" == "1" ]]; then
	open -a Simulator
fi

echo "==> running. Screenshot with: xcrun simctl io ${device_udid} screenshot ui.png"
