#!/usr/bin/env bash
# Exercise release/source provenance without replacing a developer's SDK.
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
if [[ "$1" == repo && "$2" == clone ]]; then
    if [[ -f "${FETCH_TEST_ROOT}/interrupt-clone" ]]; then
        git init -q "$4"
        rm "${FETCH_TEST_ROOT}/interrupt-clone"
        exit 1
    fi
    git clone -q "${FETCH_TEST_ROOT}/source" "$4"
    exit 0
fi
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
git -C "${source_tree}" diff HEAD --binary --src-prefix=a/ --dst-prefix=b/ \
    > "${fixture}/scripts/wavelength-ios-recovery.patch"
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

# Diff formatting cannot change source identity or alter the caller's index.
git -C "${source_tree}" config diff.noprefix true
git -C "${source_tree}" config diff.mnemonicPrefix true
git -C "${source_tree}" config core.abbrev 12
git -C "${source_tree}" config diff.context 10
git -C "${source_tree}" config diff.external false
index_before="$(shasum -a 256 "${source_tree}/.git/index")"
WAVELENGTH_DIR="${source_tree}" bash "${fetch}" --if-needed
test "$(shasum -a 256 "${source_tree}/.git/index")" == "${index_before}"
test "$(wc -l < "${fixture}/builds" | tr -d ' ')" == 2

# Plain git apply leaves new bridge files untracked. Explain the required
# staging step rather than claiming the user has not applied the patch.
git -C "${source_tree}" reset -q HEAD -- sdk/wavewalletdk/mobile/bridge
if WAVELENGTH_DIR="${source_tree}" bash "${fetch}" --if-needed 2>"${fixture}/plain-apply-error"; then
    echo 'expected unstaged bridge rejection' >&2
    exit 1
fi
grep -q 'apply --index' "${fixture}/plain-apply-error"
git -C "${source_tree}" add sdk/wavewalletdk/mobile/bridge

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
test "$(wc -l < "${fixture}/builds" | tr -d ' ')" == 2
echo 'fetch-xcframework source provenance tests passed'

# Managed caches isolate bridge revisions at the same upstream commit.
export XDG_CACHE_HOME="${fixture}/cache"
cache_root="${XDG_CACHE_HOME}/wavelength-mobile-ios"
old_cache="${cache_root}/${source_pin}-${bridge_digest}"
bash "${fetch}"
test -d "${old_cache}/.git"
test "$(cat "${old_cache}/sdk/wavewalletdk/mobile/bridge")" == bridge

printf 'bridge revision two\n' > "${source_tree}/sdk/wavewalletdk/mobile/bridge"
git -C "${source_tree}" -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    -c diff.external= diff HEAD --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
    > "${fixture}/scripts/wavelength-ios-recovery.patch"
bridge_digest="$(shasum -a 256 "${fixture}/scripts/wavelength-ios-recovery.patch" | awk '{print $1}')"
new_cache="${cache_root}/${source_pin}-${bridge_digest}"

# A partial .git checkout must never become the managed cache. Retry succeeds
# without touching the old cache, the installed SDK, or any user checkout.
touch "${fixture}/interrupt-clone"
if bash "${fetch}" --if-needed; then
    echo 'expected interrupted clone failure' >&2
    exit 1
fi
test ! -e "${new_cache}"
test -z "$(find "${cache_root}" -maxdepth 1 -name '*.tmp.*' -print)"
test "$(cat "${receipt}")" == "${expected_origin}"
bash "${fetch}" --if-needed
test -d "${new_cache}/.git"
test "$(cat "${new_cache}/sdk/wavewalletdk/mobile/bridge")" == 'bridge revision two'
test "$(cat "${old_cache}/sdk/wavewalletdk/mobile/bridge")" == bridge
expected_origin="source:lightninglabs/wavelength:${source_pin}:${bridge_digest}"
test "$(cat "${receipt}")" == "${expected_origin}"
test "$(wc -l < "${fixture}/builds" | tr -d ' ')" == 4

# An artifact matching the new bridge remains usable offline.
rm -rf "${new_cache}"
bash "${fetch}" --if-needed
test ! -e "${new_cache}"
test "$(wc -l < "${fixture}/builds" | tr -d ' ')" == 4
echo 'fetch-xcframework bridge cache and interrupted setup tests passed'
