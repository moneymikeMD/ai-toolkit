#!/usr/bin/env bash
#
# Selftest for git-retry.sh. Structurally offline: every case runs against a
# fake `git` on PATH, so no assertion depends on a network, a remote or a
# credential. The fake records its invocation count in a temp file, which is
# how "did it retry?" is measured rather than inferred from timing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/git-retry.sh"
PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
nope() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/      /'; }

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then ok "$name"; else nope "$name" "wanted [$want], got [$got]"; fi
}

# fake_git MODE — write a git stand-in that counts calls. MODE decides what it
# writes to stderr and what it exits with; "succeed-on-3" fails transiently
# twice then succeeds, which is the case the whole script exists for.
fake_git() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/git" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$WORK/count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$WORK/count"
case "$1" in
    transient)
        echo "ssh: connect to host github.com port 22: Operation timed out" >&2
        echo "fatal: Could not read from remote repository." >&2
        exit 128 ;;
    permanent)
        echo "! [rejected] main -> main (non-fast-forward)" >&2
        echo "error: failed to push some refs" >&2
        exit 1 ;;
    succeed-on-3)
        if [ "\$n" -lt 3 ]; then
            echo "ssh: connect to host github.com port 22: Operation timed out" >&2
            exit 128
        fi
        echo "Everything up-to-date"
        exit 0 ;;
    succeed)
        echo "Everything up-to-date"; exit 0 ;;
esac
EOF
    chmod +x "$WORK/bin/git"
    : > "$WORK/count"
}

run_sut() {
    PATH="$WORK/bin:$PATH" GIT_RETRY_BASE_DELAY=0 "$@" >/dev/null 2>&1
    echo $?
}
calls() { local n; n="$(cat "$WORK/count" 2>/dev/null)"; echo "${n:-0}"; }

fake_git succeed
rc="$(run_sut bash "$SUT" push origin main)"
check "a successful git exits 0" 0 "$rc"
check "a successful git is called exactly once" 1 "$(calls)"

fake_git permanent
rc="$(run_sut env GIT_RETRY_ATTEMPTS=3 bash "$SUT" push origin main)"
check "a rejected push keeps git's own exit code" 1 "$rc"
check "a rejected push is NOT retried" 1 "$(calls)"

fake_git transient
rc="$(run_sut env GIT_RETRY_ATTEMPTS=3 bash "$SUT" push origin main)"
check "an always-failing transport error keeps git's exit code" 128 "$rc"
check "an always-failing transport error uses every attempt" 3 "$(calls)"

fake_git succeed-on-3
rc="$(run_sut env GIT_RETRY_ATTEMPTS=4 bash "$SUT" push origin main)"
check "a transport error that clears eventually exits 0" 0 "$rc"
check "a transport error that clears stops at the success" 3 "$(calls)"

fake_git transient
rc="$(run_sut env GIT_RETRY_ATTEMPTS=1 bash "$SUT" push origin main)"
check "ATTEMPTS=1 disables retrying" 128 "$rc"
check "ATTEMPTS=1 calls git exactly once" 1 "$(calls)"

fake_git succeed
rc="$(run_sut env GIT_RETRY_ATTEMPTS=notanumber bash "$SUT" push origin main)"
check "a non-numeric ATTEMPTS is rejected before running git" 2 "$rc"
check "a non-numeric ATTEMPTS never calls git" 0 "$(calls)"

fake_git succeed
rc="$(run_sut bash "$SUT")"
check "no arguments is a usage error, not a git call" 2 "$rc"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "git-retry-selftest.sh: FAILED"; exit 1; }
echo "git-retry-selftest.sh: all assertions passed"
