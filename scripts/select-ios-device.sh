#!/usr/bin/env bash

# Select a connected physical iOS device. A caller can pin a phone by setting
# DEVICE_UDID; otherwise the first connected device reported by devicectl is
# used.

set -euo pipefail

requested_udid="${DEVICE_UDID:-}"
devices="$(xcrun devicectl list devices)"

extract_udid() {
	grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
		| head -1
}

if [[ -n "${requested_udid}" ]]; then
	device_line="$(grep -F "${requested_udid}" <<<"${devices}" || true)"
	if [[ -z "${device_line}" || "${device_line}" != *" connected "* ]]; then
		echo "error: DEVICE_UDID=${requested_udid} is not connected" >&2
		echo "Connect and unlock the phone, then run 'make device'." >&2
		exit 1
	fi

	device_udid="$(extract_udid <<<"${device_line}")"
else
	device_udid="$(grep ' connected ' <<<"${devices}" \
		| extract_udid || true)"
fi

if [[ -z "${device_udid:-}" ]]; then
	echo "error: no connected physical iOS device found" >&2
	echo "Connect and unlock the phone, trust this Mac, and enable Developer Mode." >&2
	exit 1
fi

printf '%s\n' "${device_udid}"
