#!/usr/bin/env bash

# Relaunch the installed sample app on a physical device and keep its stdout
# and stderr attached to this terminal. Go mobile logs are emitted to stdout,
# so this captures the embedded daemon and the Swift app in one live stream.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:-engineering.lightning.wavelength.wallet}"

device_udid="$("${REPO_ROOT}/scripts/select-ios-device.sh")"

echo "==> using physical device ${device_udid}"
echo "==> launching ${BUNDLE_ID} with a live console"
echo "==> press Ctrl-C to detach; the app remains installed"

exec xcrun devicectl device process launch \
	--console \
	--terminate-existing \
	--device "${device_udid}" \
	"${BUNDLE_ID}"
