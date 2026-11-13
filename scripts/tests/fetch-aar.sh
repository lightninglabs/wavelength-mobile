#!/usr/bin/env bash
# Artifact cache identity must include the exact source and bridge, not existence.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/scripts" "${fixture}/android/walletkit/libs"
cp "${root}/scripts/fetch-aar.sh" "${root}/scripts/wavelength-ios-recovery.patch" "${fixture}/scripts/"
cp "${root}/.wavelength-version" "${fixture}/.wavelength-version"
pin="$(cat "${fixture}/.wavelength-version")"
digest="$(shasum -a 256 "${fixture}/scripts/wavelength-ios-recovery.patch" | awk '{print $1}')"
artifact="${fixture}/android/walletkit/libs/Wavewalletdk.aar"
printf 'fixture\n' > "${artifact}"
printf 'source:lightninglabs/wavelength:%s:%s\n' "${pin}" "${digest}" > "${artifact}.origin"
unset WAVELENGTH_DIR WAVELENGTH_VERSION WAVELENGTH_REPO
# Matching provenance returns without requiring the Android toolchain.
bash "${fixture}/scripts/fetch-aar.sh" --if-needed
# An explicitly supplied wrong revision must not reuse that cached artifact.
mkdir "${fixture}/source"
git -C "${fixture}/source" init -q
git -C "${fixture}/source" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --allow-empty -qm initial
if WAVELENGTH_DIR="${fixture}/source" bash "${fixture}/scripts/fetch-aar.sh" --if-needed; then
  echo 'expected mismatched source revision to fail' >&2
  exit 1
fi
test "$(cat "${artifact}")" == fixture
echo 'fetch-aar provenance tests passed'
