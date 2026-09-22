#!/usr/bin/env bash
#
# Selftest for lib/ghkit.sh. Offline: every case runs against a fake `gh` on
# PATH, so no assertion depends on a network, a credential or a real repo.
#
# Usage: ghkit-selftest.sh [path-to-ghkit.sh]
# Defaults to the sibling lib/ghkit.sh. Pass an older revision's path to
# reproduce the RED failures against pre-fix code.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHKIT="${1:-$HERE/lib/ghkit.sh}"
[ -r "$GHKIT" ] || { echo "cannot read $GHKIT" >&2; exit 2; }

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
nope() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/       /'; }
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then ok "$name"; else nope "$name" "wanted [$want], got [$got]"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${GHKIT_STUB_ERR:-}" ]; then
    printf '%s\n' "$GHKIT_STUB_ERR" >&2
    exit "${GHKIT_STUB_EXIT:-1}"
fi
printf '%s\n' "${GHKIT_STUB_OUT:-}"
exit 0
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# shellcheck source=lib/ghkit.sh
. "$GHKIT"

run() {
    CONTEXTS="sentinel-never-read"
    gh_required_contexts o/r main CONTEXTS
    RC=$?
}

echo "== a readable branch with required contexts"
GHKIT_STUB_ERR="" GHKIT_STUB_OUT=$'self-lint\nselftest' run
check "returns 0" "0" "$RC"
check "the contexts come back sorted and de-duplicated" "self-lint selftest" \
    "$(printf '%s' "$CONTEXTS" | tr '\n' ' ' | sed 's/ $//')"

GHKIT_STUB_ERR="" GHKIT_STUB_OUT=$'ci\nci\nci' run
check "a repeated context appears once" "ci" "$CONTEXTS"

echo "== a readable branch that requires nothing"
GHKIT_STUB_ERR="" GHKIT_STUB_OUT="" run
check "measured-and-none returns 0, not an error" "0" "$RC"
check "and the list is empty" "" "$CONTEXTS"

echo "== rules that cannot be read are their own outcome"
GHKIT_STUB_ERR="gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" \
    GHKIT_STUB_EXIT=1 run
check "a 403 returns 3, never 0" "3" "$RC"
check "and leaves the list empty rather than an error string" "" "$CONTEXTS"

GHKIT_STUB_ERR="gh: Not Found (HTTP 404)" GHKIT_STUB_EXIT=1 run
check "a 404 returns 3 as well" "3" "$RC"

echo "== anything else is a failure, not an absence"
GHKIT_STUB_ERR="gh: Bad credentials (HTTP 401)" GHKIT_STUB_EXIT=1 run
check "a 401 returns 1, so a broken credential can never read as 'no checks'" "1" "$RC"
check "and hands the caller the error text to print" "yes" \
    "$(printf '%s' "$CONTEXTS" | grep -q 'Bad credentials' && echo yes || echo no)"

GHKIT_STUB_ERR="dial tcp: lookup api.github.com: no such host" GHKIT_STUB_EXIT=1 run
check "a transport fault returns 1, not 3" "1" "$RC"

echo "== the three outcomes are distinguishable, which is the whole point"
GHKIT_STUB_ERR="" GHKIT_STUB_OUT="" run
EMPTY_RC="$RC"
GHKIT_STUB_ERR="gh: (HTTP 403)" GHKIT_STUB_EXIT=1 run
UNREADABLE_RC="$RC"
check "measured-and-none and cannot-be-measured are not the same code" "different" \
    "$([ "$EMPTY_RC" = "$UNREADABLE_RC" ] && echo same || echo different)"

echo "== usage"
CONTEXTS=""
gh_required_contexts o/r main 2>/dev/null
check "too few arguments is a usage error, not a silent empty answer" "2" "$?"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed (against: $GHKIT)"
[ "$FAIL" -eq 0 ]
