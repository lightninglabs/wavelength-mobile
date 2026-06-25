#!/usr/bin/env bash
#
# fetch-aar.sh builds the walletdk gomobile bindings from a sibling
# darepo-client checkout and copies the resulting Android .aar into the sample
# app at android/app/libs/Walletdk.aar (which is gitignored).
#
# The .aar is a large (100MB+) native artifact, so it is never committed here;
# run this script once after cloning, and again whenever the SDK changes.
#
# Configuration (env vars, all optional):
#   DAREPO_CLIENT_DIR  path to the darepo-client checkout
#                      (default: ../darepo-client next to this repo)
#   JAVA_HOME          a modern JDK (17+); auto-detected from Homebrew if unset
#   GOPATH             must not equal GOROOT (gomobile/lint footgun)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAREPO_CLIENT_DIR="${DAREPO_CLIENT_DIR:-$(cd "${REPO_ROOT}/.." && pwd)/darepo-client}"

if [[ ! -d "${DAREPO_CLIENT_DIR}/sdk/walletdk/mobile" ]]; then
	echo "error: darepo-client not found at ${DAREPO_CLIENT_DIR}" >&2
	echo "set DAREPO_CLIENT_DIR to your darepo-client checkout" >&2
	exit 1
fi

# A modern JDK is required to assemble the .aar (JDK 8 is too old). Prefer an
# explicit JAVA_HOME, else fall back to a Homebrew openjdk.
if [[ -z "${JAVA_HOME:-}" ]]; then
	for candidate in /opt/homebrew/opt/openjdk@17 /opt/homebrew/opt/openjdk; do
		if [[ -x "${candidate}/bin/javac" ]]; then
			JAVA_HOME="${candidate}"
			break
		fi
	done
fi
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

# gomobile and the Go linter both misbehave when GOPATH == GOROOT; point GOPATH
# at the checkout's parent gopath if it currently collides with GOROOT.
if [[ "$(go env GOPATH)" == "$(go env GOROOT)" ]]; then
	export GOPATH="${HOME}/gocode"
fi
export PATH="$(go env GOPATH)/bin:${PATH}"

echo "==> building Walletdk.aar from ${DAREPO_CLIENT_DIR}"
( cd "${DAREPO_CLIENT_DIR}" && make mobile-android )

SRC_AAR="${DAREPO_CLIENT_DIR}/sdk/walletdk/mobile/build/android/Walletdk.aar"
DST_DIR="${REPO_ROOT}/android/app/libs"
mkdir -p "${DST_DIR}"
cp "${SRC_AAR}" "${DST_DIR}/Walletdk.aar"

echo "==> copied $(du -h "${DST_DIR}/Walletdk.aar" | cut -f1) -> android/app/libs/Walletdk.aar"
