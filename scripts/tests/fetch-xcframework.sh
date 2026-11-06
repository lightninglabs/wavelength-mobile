#!/usr/bin/env bash
# Exercise release changes without downloading or replacing a developer's SDK.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
mkdir -p "${fixture}/scripts" "${fixture}/bin"
cp "${root}/scripts/fetch-xcframework.sh" "${fixture}/scripts/"
printf 'v0.1.2\n' > "${fixture}/.wavelength-ios-version"
export FETCH_TEST_ROOT="${fixture}"
export PATH="${fixture}/bin:${PATH}"
unset WAVELENGTH_DIR WAVELENGTH_VERSION WAVELENGTH_REPO

cat > "${fixture}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${FETCH_TEST_ROOT}/downloads"
[[ ! -f "${FETCH_TEST_ROOT}/fail-download" ]]
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--dir" ]]; then
        mkdir -p "$2/Wavewalletdk.xcframework"
        printf 'fixture\n' > "$2/Wavewalletdk.xcframework/Info.plist"
        tar -czf "$2/Wavewalletdk.xcframework.tar.gz" -C "$2" Wavewalletdk.xcframework
        rm -rf "$2/Wavewalletdk.xcframework"
        exit 0
    fi
    shift
done
exit 1
MOCK
chmod +x "${fixture}/bin/gh"
fetch="${fixture}/scripts/fetch-xcframework.sh"
framework="${fixture}/ios/WalletKit/Frameworks/Wavewalletdk.xcframework"
receipt="${framework}/.wavelength-origin"

# An existing directory without provenance must not silently satisfy the pin.
mkdir -p "${framework}"
bash "${fetch}" --if-needed
test "$(cat "${receipt}")" == 'release:lightninglabs/wavelength:v0.1.2'
bash "${fetch}" --if-needed
test "$(wc -l < "${fixture}/downloads" | tr -d ' ')" == 1

# A changed pin replaces the artifact; a matching pin uses it offline.
printf 'v0.2.1\n' > "${fixture}/.wavelength-ios-version"
bash "${fetch}" --if-needed
test "$(cat "${receipt}")" == 'release:lightninglabs/wavelength:v0.2.1'
touch "${fixture}/fail-download"
bash "${fetch}" --if-needed
test "$(wc -l < "${fixture}/downloads" | tr -d ' ')" == 2

# A failed replacement leaves the installed SDK and its receipt intact.
if WAVELENGTH_VERSION=v9.9.9 bash "${fetch}" --if-needed; then
    echo 'expected download failure' >&2
    exit 1
fi
test -f "${framework}/Info.plist"
test "$(cat "${receipt}")" == 'release:lightninglabs/wavelength:v0.2.1'
rm "${fixture}/fail-download"

# An explicit override and returning to the repository pin both refresh it.
WAVELENGTH_VERSION=v0.2.0 bash "${fetch}" --if-needed
test "$(cat "${receipt}")" == 'release:lightninglabs/wavelength:v0.2.0'
bash "${fetch}" --if-needed
test "$(cat "${receipt}")" == 'release:lightninglabs/wavelength:v0.2.1'
echo 'fetch-xcframework release cache tests passed'

# Source pins must match both the commit and the complete bridge diff.
source_tree="${fixture}/source"
mkdir -p "${source_tree}/sdk/wavewalletdk/mobile"
git -C "${source_tree}" init -q
printf 'sdk/wavewalletdk/mobile/build/\n' > "${source_tree}/.gitignore"
printf 'base\n' > "${source_tree}/sdk/wavewalletdk/mobile/base"
git -C "${source_tree}" add .
git -C "${source_tree}" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm 'Fixture SDK'
source_pin="$(git -C "${source_tree}" rev-parse HEAD)"
printf '%s\n' "${source_pin}" > "${fixture}/.wavelength-ios-version"
printf 'bridge\n' > "${source_tree}/sdk/wavewalletdk/mobile/bridge"
git -C "${source_tree}" add .
git -C "${source_tree}" diff HEAD --binary > "${fixture}/scripts/wavelength-ios-recovery.patch"
bridge_digest="$(shasum -a 256 "${fixture}/scripts/wavelength-ios-recovery.patch" | awk '{print $1}')"
cat > "${fixture}/bin/make" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p sdk/wavewalletdk/mobile/build/ios/Wavewalletdk.xcframework
printf 'source fixture\n' > sdk/wavewalletdk/mobile/build/ios/Wavewalletdk.xcframework/Info.plist
echo build >> "${FETCH_TEST_ROOT}/builds"
MOCK
chmod +x "${fixture}/bin/make"
WAVELENGTH_DIR="${source_tree}" bash "${fetch}" --if-needed
expected_origin="source:lightninglabs/wavelength:${source_pin}:${bridge_digest}"
test "$(cat "${receipt}")" == "${expected_origin}"
# Cached source artifacts can be used offline without a checkout or toolchain.
bash "${fetch}" --if-needed
test "$(wc -l < "${fixture}/builds" | tr -d ' ')" == 1

# An edited bridge or unexpected untracked source must fail before building.
printf 'changed\n' >> "${source_tree}/sdk/wavewalletdk/mobile/bridge"
if WAVELENGTH_DIR="${source_tree}" bash "${fetch}" --if-needed; then
    echo 'expected source diff mismatch' >&2
    exit 1
fi
git -C "${source_tree}" checkout -- sdk/wavewalletdk/mobile/bridge
printf 'untracked\n' > "${source_tree}/unexpected.go"
if WAVELENGTH_DIR="${source_tree}" bash "${fetch}" --if-needed; then
    echo 'expected untracked source rejection' >&2
    exit 1
fi
rm "${source_tree}/unexpected.go"
test "$(cat "${receipt}")" == "${expected_origin}"
test "$(cat "${framework}/Info.plist")" == 'source fixture'
test "$(wc -l < "${fixture}/builds" | tr -d ' ')" == 1
echo 'fetch-xcframework source provenance tests passed'
