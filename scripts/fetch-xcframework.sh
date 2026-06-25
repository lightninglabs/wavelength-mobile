#!/usr/bin/env bash
#
# fetch-xcframework.sh builds the walletdk gomobile bindings for iOS from a
# sibling darepo-client checkout and stages the resulting xcframework into the
# Swift package at ios/WalletKit/Frameworks/Walletdk.xcframework (gitignored).
#
# Requires macOS with Xcode installed.
#
# Configuration (env vars, all optional):
#   DAREPO_CLIENT_DIR  path to the darepo-client checkout
#                      (default: ../darepo-client next to this repo)
#   GOPATH             must not equal GOROOT (gomobile footgun)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAREPO_CLIENT_DIR="${DAREPO_CLIENT_DIR:-$(cd "${REPO_ROOT}/.." && pwd)/darepo-client}"

if [[ ! -d "${DAREPO_CLIENT_DIR}/sdk/walletdk/mobile" ]]; then
	echo "error: darepo-client not found at ${DAREPO_CLIENT_DIR}" >&2
	echo "set DAREPO_CLIENT_DIR to your darepo-client checkout" >&2
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

echo "==> building Walletdk.xcframework from ${DAREPO_CLIENT_DIR}"
( cd "${DAREPO_CLIENT_DIR}" && make mobile-ios )

SRC="${DAREPO_CLIENT_DIR}/sdk/walletdk/mobile/build/ios/Walletdk.xcframework"
DST_DIR="${REPO_ROOT}/ios/WalletKit/Frameworks"
mkdir -p "${DST_DIR}"
rm -rf "${DST_DIR}/Walletdk.xcframework"
cp -R "${SRC}" "${DST_DIR}/Walletdk.xcframework"

echo "==> staged -> ios/WalletKit/Frameworks/Walletdk.xcframework"
