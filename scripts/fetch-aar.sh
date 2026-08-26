#!/usr/bin/env bash
#
# fetch-aar.sh stages the Wavewalletdk.aar gomobile binding into the wrapper
# module at android/walletkit/libs/Wavewalletdk.aar (which is gitignored).
#
# By default it downloads the binding from the wavelength GitHub release, so no
# Go / Android / gomobile toolchain is needed on this machine. Point
# WAVELENGTH_DIR at a local wavelength checkout to build from source instead,
# e.g. when testing an unreleased change.
#
# The .aar is a large (150MB+) native artifact, so it is never committed here;
# run this once after cloning, and again whenever the pinned daemon changes.
#
# Configuration (env vars, all optional):
#   WAVELENGTH_VERSION  release tag to download (default: the latest release)
#   WAVELENGTH_REPO     owner/name of the wavelength repo
#                       (default: lightninglabs/wavelength)
#   WAVELENGTH_DIR      path to a wavelength checkout; when set, build from
#                       source instead of downloading the release asset
#   JAVA_HOME           a modern JDK (17+); source builds only
#   GOPATH              must not equal GOROOT (gomobile/lint footgun)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST_DIR="${REPO_ROOT}/android/walletkit/libs"
DST="${DST_DIR}/Wavewalletdk.aar"
WAVELENGTH_REPO="${WAVELENGTH_REPO:-lightninglabs/wavelength}"
mkdir -p "${DST_DIR}"

# Source build: only when WAVELENGTH_DIR points at a checkout. This path needs
# the full Android + gomobile toolchain and is meant for iterating against an
# unreleased daemon.
if [[ -n "${WAVELENGTH_DIR:-}" ]]; then
	if [[ ! -d "${WAVELENGTH_DIR}/sdk/wavewalletdk/mobile" ]]; then
		echo "error: wavelength checkout not found at ${WAVELENGTH_DIR}" >&2
		echo "unset WAVELENGTH_DIR to download the release asset instead" >&2
		exit 1
	fi

	# A modern JDK is required to assemble the .aar (JDK 8 is too old). Prefer
	# an explicit JAVA_HOME, else fall back to a Homebrew openjdk.
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

	# gomobile and the Go linter both misbehave when GOPATH == GOROOT; point
	# GOPATH elsewhere if it currently collides with GOROOT.
	if [[ "$(go env GOPATH)" == "$(go env GOROOT)" ]]; then
		export GOPATH="${HOME}/gocode"
	fi
	export PATH="$(go env GOPATH)/bin:${PATH}"

	echo "==> building Wavewalletdk.aar from ${WAVELENGTH_DIR}"
	( cd "${WAVELENGTH_DIR}" && make mobile-android )

	cp "${WAVELENGTH_DIR}/sdk/wavewalletdk/mobile/build/android/Wavewalletdk.aar" "${DST}"
	echo "==> staged $(du -h "${DST}" | cut -f1) -> android/walletkit/libs/Wavewalletdk.aar"
	exit 0
fi

# Default: download the binding from the GitHub release. Use an authenticated
# gh CLI so repository access and release-asset redirects work consistently.
if ! command -v gh >/dev/null 2>&1; then
	echo "error: gh CLI not found; install it and run 'gh auth login', or set" >&2
	echo "       WAVELENGTH_DIR to build from a local wavelength checkout." >&2
	exit 1
fi

# The release tag is an optional positional arg to `gh release download`
# (omitted => latest). Invoke the two forms separately rather than expanding a
# maybe-empty array: under `set -u`, macOS's stock bash 3.2 aborts on
# "${arr[@]}" when arr is empty ("unbound variable").
echo "==> downloading Wavewalletdk.aar from ${WAVELENGTH_REPO} (${WAVELENGTH_VERSION:-latest})"
if [[ -n "${WAVELENGTH_VERSION:-}" ]]; then
	gh release download "${WAVELENGTH_VERSION}" --repo "${WAVELENGTH_REPO}" \
		--pattern "Wavewalletdk.aar" --dir "${DST_DIR}" --clobber
else
	gh release download --repo "${WAVELENGTH_REPO}" \
		--pattern "Wavewalletdk.aar" --dir "${DST_DIR}" --clobber
fi

echo "==> staged $(du -h "${DST}" | cut -f1) -> android/walletkit/libs/Wavewalletdk.aar"
