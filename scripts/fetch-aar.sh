#!/usr/bin/env bash
#
# fetch-aar.sh stages the Wavewalletdk.aar gomobile binding
# into android/walletkit/libs/Wavewalletdk.aar
# (which is gitignored).
#
# Commit pins build the exact source plus the checked-in mobile bridge. Release
# tags download a packaged binding. Source builds require the Android SDK/NDK,
# JDK 17+, Go, and gomobile. WAVELENGTH_DIR can select an exactly matching prepared checkout.
#
# Configuration (env vars, all optional):
#   WAVELENGTH_VERSION  source commit or release tag (default: repository pin)
#   WAVELENGTH_REPO     owner/name of the wavelength repo
#                       (default: lightninglabs/wavelength)
#   WAVELENGTH_DIR      path to a wavelength checkout; when set, build from
#                       source instead of downloading the release asset
#   XDG_CACHE_HOME      managed source cache root (default: ~/.cache)
#   GOPATH              must not equal GOROOT (gomobile footgun)

set -euo pipefail

if_needed=false
if [[ "${1:-}" == "--if-needed" && $# == 1 ]]; then
	if_needed=true
elif [[ $# != 0 ]]; then
	echo "usage: $0 [--if-needed]" >&2
	exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST_DIR="${REPO_ROOT}/android/walletkit/libs"
DST="${DST_DIR}/Wavewalletdk.aar"
WAVELENGTH_REPO="${WAVELENGTH_REPO:-lightninglabs/wavelength}"
WAVELENGTH_VERSION="${WAVELENGTH_VERSION:-$(cat "${REPO_ROOT}/.wavelength-version")}"
receipt="${DST}.origin"
release_origin="release:${WAVELENGTH_REPO}:${WAVELENGTH_VERSION}"
mkdir -p "${DST_DIR}"

# A commit pin builds the unreleased SDK together with the narrow mobile ABI
# additions carried in this repository. Include the patch digest in provenance
# so a previously staged release or another bridge revision cannot be reused.
if [[ "${WAVELENGTH_VERSION}" =~ ^[0-9a-f]{40}$ ]]; then
	bridge_patch="${REPO_ROOT}/scripts/wavelength-ios-recovery.patch"
	bridge_digest="$(shasum -a 256 "${bridge_patch}" | awk '{print $1}')"
	source_origin="source:${WAVELENGTH_REPO}:${WAVELENGTH_VERSION}:${bridge_digest}"
	if ${if_needed} && [[ -z "${WAVELENGTH_DIR:-}" && -f "${DST}" && -f "${receipt}" ]] && \
		[[ "$(cat "${receipt}")" == "${source_origin}" ]]; then
		echo "==> using pinned Wavelength Android SDK (${WAVELENGTH_VERSION})"
		exit 0
	fi
	if [[ -n "${WAVELENGTH_DIR:-}" ]]; then
		source_tree="${WAVELENGTH_DIR}"
	else
		# A new bridge gets a separate checkout. Publish it only after setup
		# succeeds, so an interrupted clone or apply can be retried normally.
		cache_root="${XDG_CACHE_HOME:-${HOME}/.cache}/wavelength-mobile-android"
		source_tree="${cache_root}/${WAVELENGTH_VERSION}-${bridge_digest}"
		if [[ ! -d "${source_tree}" ]]; then
			mkdir -p "${cache_root}"
			source_tmp="$(mktemp -d "${source_tree}.tmp.XXXXXX")"
			trap 'rm -rf "${source_tmp}"' EXIT
			gh repo clone "${WAVELENGTH_REPO}" "${source_tmp}" -- --filter=blob:none --no-checkout
			git -C "${source_tmp}" fetch origin "${WAVELENGTH_VERSION}" --depth=1
			git -C "${source_tmp}" checkout --detach "${WAVELENGTH_VERSION}"
			git -C "${source_tmp}" apply --index "${bridge_patch}"
			mv "${source_tmp}" "${source_tree}"
			trap - EXIT
		fi
	fi
	if [[ "$(git -C "${source_tree}" rev-parse HEAD)" != "${WAVELENGTH_VERSION}" ]]; then
		echo "error: WAVELENGTH_DIR does not match the pinned SDK commit" >&2
		exit 1
	fi
	# Compare file content, not rendered diff bytes: user diff prefixes,
	# context, algorithms, and object abbreviations must not affect identity.
	# A temporary index leaves an explicitly supplied checkout's index intact.
	index_tmp="$(mktemp -d)"
	trap 'rm -rf "${index_tmp}"' EXIT
	GIT_INDEX_FILE="${index_tmp}/index" git -C "${source_tree}" read-tree HEAD
	GIT_INDEX_FILE="${index_tmp}/index" git -C "${source_tree}" apply --cached "${bridge_patch}"
	expected_tree="$(GIT_INDEX_FILE="${index_tmp}/index" git -C "${source_tree}" write-tree)"
	rm -rf "${index_tmp}"
	trap - EXIT
	if ! git -C "${source_tree}" diff --quiet --no-ext-diff --no-textconv "${expected_tree}" -- || \
		[[ -n "$(git -C "${source_tree}" ls-files --others --exclude-standard)" ]]; then
		echo "error: SDK bridge differs from scripts/wavelength-ios-recovery.patch" >&2
		echo "Use a clean pinned checkout and apply the bridge with --index:" >&2
		printf '  git -C %q apply --index %q\n' "${source_tree}" "${bridge_patch}" >&2
		echo "If already applied without --index, stage the bridge's new files." >&2
		echo "Unset WAVELENGTH_DIR to use a managed source checkout instead." >&2
		exit 1
	fi
	export PATH="$(go env GOPATH)/bin:${PATH}"
	( cd "${source_tree}" && make mobile-android )
	rm -rf "${DST}"
	cp -R "${source_tree}/sdk/wavewalletdk/mobile/build/android/Wavewalletdk.aar" "${DST}"
	printf '%s\n' "${source_origin}" > "${receipt}"
	echo "==> staged pinned Android SDK (${WAVELENGTH_VERSION})"
	exit 0
fi

# An artifact alone says nothing about the staged SDK version. Reuse only an
# artifact installed by this script for the requested release. Source builds
# deliberately bypass this cache so local edits are rebuilt.
if ${if_needed} && [[ -z "${WAVELENGTH_DIR:-}" && -f "${DST}" && -f "${receipt}" ]] && \
	[[ "$(cat "${receipt}")" == "${release_origin}" ]]; then
	echo "==> using Wavewalletdk.aar (${WAVELENGTH_VERSION})"
	exit 0
fi

# Release tags retain the packaged-binding workflow.
if [[ -n "${WAVELENGTH_DIR:-}" ]]; then
    echo "error: source builds require a full commit pin" >&2
    exit 1
fi

gh release download "${WAVELENGTH_VERSION}" --repo "${WAVELENGTH_REPO}" \
    --pattern "Wavewalletdk.aar" --dir "${DST_DIR}" --clobber
printf '%s\n' "${release_origin}" > "${receipt}"
echo "==> staged -> android/walletkit/libs/Wavewalletdk.aar"
