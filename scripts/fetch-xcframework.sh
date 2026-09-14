#!/usr/bin/env bash
#
# fetch-xcframework.sh stages the Wavewalletdk.xcframework gomobile binding
# into the Swift package at ios/WalletKit/Frameworks/Wavewalletdk.xcframework
# (which is gitignored).
#
# By default it downloads the binding from the wavelength GitHub release, which
# needs no toolchain. Point WAVELENGTH_DIR at a local wavelength checkout to
# build from source instead (requires macOS with Xcode).
#
# Configuration (env vars, all optional):
#   WAVELENGTH_VERSION  release tag to download (default: .wavelength-version)
#   WAVELENGTH_REPO     owner/name of the wavelength repo
#                       (default: lightninglabs/wavelength)
#   WAVELENGTH_DIR      path to a wavelength checkout; when set, build from
#                       source instead of downloading the release asset
#   GOPATH              must not equal GOROOT (gomobile footgun)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST_DIR="${REPO_ROOT}/ios/WalletKit/Frameworks"
DST="${DST_DIR}/Wavewalletdk.xcframework"
WAVELENGTH_REPO="${WAVELENGTH_REPO:-lightninglabs/wavelength}"
WAVELENGTH_VERSION="${WAVELENGTH_VERSION:-$(cat "${REPO_ROOT}/.wavelength-version")}"
mkdir -p "${DST_DIR}"

# Source build: only when WAVELENGTH_DIR points at a checkout. Requires macOS
# with Xcode and is meant for iterating against an unreleased daemon.
if [[ -n "${WAVELENGTH_DIR:-}" ]]; then
	if [[ ! -d "${WAVELENGTH_DIR}/sdk/wavewalletdk/mobile" ]]; then
		echo "error: wavelength checkout not found at ${WAVELENGTH_DIR}" >&2
		echo "unset WAVELENGTH_DIR to download the release asset instead" >&2
		exit 1
	fi

	if [[ "$(uname)" != "Darwin" ]]; then
		echo "error: building the iOS xcframework requires macOS + Xcode" >&2
		exit 1
	fi

	if [[ "$(go env GOPATH)" == "$(go env GOROOT)" ]]; then
		export GOPATH="${HOME}/gocode"
	fi
	export PATH="$(go env GOPATH)/bin:${PATH}"

	echo "==> building Wavewalletdk.xcframework from ${WAVELENGTH_DIR}"
	( cd "${WAVELENGTH_DIR}" && make mobile-ios )

	rm -rf "${DST}"
	cp -R "${WAVELENGTH_DIR}/sdk/wavewalletdk/mobile/build/ios/Wavewalletdk.xcframework" "${DST}"
	echo "==> staged -> ios/WalletKit/Frameworks/Wavewalletdk.xcframework"
	exit 0
fi

# Default: download the packaged binding from the GitHub release and unpack it.
# The release asset is a tarball (Wavewalletdk.xcframework.tar.gz) since an
# .xcframework is a directory. Use an authenticated gh CLI so repository
# access and release-asset redirects work consistently.
if ! command -v gh >/dev/null 2>&1; then
	echo "error: gh CLI not found; install it and run 'gh auth login', or set" >&2
	echo "       WAVELENGTH_DIR to build from a local wavelength checkout." >&2
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "==> downloading Wavewalletdk.xcframework from ${WAVELENGTH_REPO} (${WAVELENGTH_VERSION})"
gh release download "${WAVELENGTH_VERSION}" --repo "${WAVELENGTH_REPO}" \
	--pattern "Wavewalletdk.xcframework.tar.gz" --dir "${tmp}" --clobber

rm -rf "${DST}"
tar -xzf "${tmp}/Wavewalletdk.xcframework.tar.gz" -C "${DST_DIR}"
echo "==> staged -> ios/WalletKit/Frameworks/Wavewalletdk.xcframework"
