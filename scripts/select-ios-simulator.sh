#!/usr/bin/env bash

# Select and boot an iPhone Simulator. A caller can pin a device by setting
# SIMULATOR_UDID; otherwise a booted iPhone is preferred, followed by the first
# available iPhone. A device is created only when no iPhone Simulator exists.

set -euo pipefail

requested_udid="${SIMULATOR_UDID:-}"
devices="$(xcrun simctl list devices available)"

extract_udid() {
	grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
		| head -1
}

if [[ -n "${requested_udid}" ]]; then
	if ! grep -q "${requested_udid}" <<<"${devices}"; then
		echo "error: SIMULATOR_UDID=${requested_udid} is not an available Simulator" >&2
		echo "Run 'make simulator' without SIMULATOR_UDID to select one automatically." >&2
		exit 1
	fi
	device_udid="${requested_udid}"
else
	device_udid="$(grep 'iPhone.*(Booted)' <<<"${devices}" | extract_udid || true)"
	if [[ -z "${device_udid}" ]]; then
		device_udid="$(grep 'iPhone' <<<"${devices}" | extract_udid || true)"
	fi
fi

if [[ -z "${device_udid:-}" ]]; then
	runtime="$(xcrun simctl list runtimes available \
		| grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS[-0-9]+' \
		| tail -1)"
	devtype="$(xcrun simctl list devicetypes \
		| grep 'iPhone' \
		| grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone[-0-9A-Za-z]+' \
		| tail -1)"

	if [[ -z "${runtime}" || -z "${devtype}" ]]; then
		echo "error: no iPhone Simulator or usable iOS runtime is installed" >&2
		echo "Install a runtime with: xcodebuild -downloadPlatform iOS" >&2
		exit 1
	fi

	echo "Creating Wavelength iPhone Simulator (${devtype}, ${runtime})" >&2
	device_udid="$(xcrun simctl create \
		'wavelength-mobile-iphone' "${devtype}" "${runtime}")"
fi

state="$(xcrun simctl list devices | grep "${device_udid}" || true)"
if [[ "${state}" != *"(Booted)"* ]]; then
	echo "Booting iPhone Simulator ${device_udid}" >&2
	xcrun simctl boot "${device_udid}"
fi
xcrun simctl bootstatus "${device_udid}" -b >&2

printf '%s\n' "${device_udid}"
