#!/usr/bin/env bash
#
# Selftest for tag-major.sh. Structurally offline: every case runs against
# a fake `gh` on PATH driven entirely by TAGMAJ_STUB_* environment
# variables, so no assertion depends on a network, a remote or a
# credential.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/tag-major.sh"
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

# fake_gh — one stand-in for every gh call tag-major.sh makes. A create
# flips TAGMAJ_STUB_EXISTS_FILE, so a POST then a read-back behaves like
# the real two calls; --jq runs through real jq so the script's own
# parsing of the response shape is under test.
fake_gh() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
count_file="$TAGMAJ_STUB_COUNTFILE"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    echo "$TAGMAJ_STUB_REPO_NAMEWITHOWNER"
    exit 0
fi

if [ "$1" = "api" ]; then
    method="GET"
    jqfilter=""
    shift
    args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -X) method="$2"; shift 2 ;;
            -f|-F) args+=("$2"); shift 2 ;;
            --paginate) shift ;;
            --jq) jqfilter="$2"; shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    endpoint="${args[0]:-}"
    case "$endpoint" in
        repos/*/tags)
            printf '%s\n' "$TAGMAJ_STUB_TAGS_JSON"
            exit 0
            ;;
        repos/*/git/ref/tags/*)
            if [ "$(cat "$TAGMAJ_STUB_EXISTS_FILE")" = "true" ]; then
                body="$(printf '{"object":{"sha":"%s"}}' "$TAGMAJ_STUB_REF_SHA")"
                if [ -n "$jqfilter" ]; then
                    printf '%s' "$body" | jq -r "$jqfilter"
                else
                    printf '%s\n' "$body"
                fi
                exit 0
            fi
            echo "not found" >&2
            exit 1
            ;;
        repos/*/git/refs/tags/*)
            [ "$method" = "PATCH" ] || { echo "fake gh: unexpected method $method for $endpoint" >&2; exit 1; }
            echo "PATCH $endpoint" >> "$TAGMAJ_STUB_WRITE_LOG"
            exit "${TAGMAJ_STUB_WRITE_EXIT:-0}"
            ;;
        repos/*/git/refs)
            [ "$method" = "POST" ] || { echo "fake gh: unexpected method $method for $endpoint" >&2; exit 1; }
            echo "POST $endpoint" >> "$TAGMAJ_STUB_WRITE_LOG"
            [ "${TAGMAJ_STUB_WRITE_EXIT:-0}" = "0" ] && echo true > "$TAGMAJ_STUB_EXISTS_FILE"
            exit "${TAGMAJ_STUB_WRITE_EXIT:-0}"
            ;;
    esac
    echo "fake gh: unhandled api call: ${args[*]}" >&2
    exit 1
fi

echo "fake gh: unhandled invocation: $*" >&2
exit 1
STUB
    chmod +x "$WORK/bin/gh"
}

reset_scenario() {
    TAGMAJ_STUB_COUNTFILE="$WORK/count"
    TAGMAJ_STUB_WRITE_LOG="$WORK/writes.log"
    TAGMAJ_STUB_EXISTS_FILE="$WORK/ref-exists"
    : > "$TAGMAJ_STUB_COUNTFILE"
    : > "$TAGMAJ_STUB_WRITE_LOG"
    TAGMAJ_STUB_REPO_NAMEWITHOWNER="test-owner/test-repo"
    TAGMAJ_STUB_TAGS_JSON=$'v1.2.0\tabc111\nv1.9.0\taaa222\nv1.10.0\tbbb333'
    TAGMAJ_STUB_REF_EXISTS="true"
    TAGMAJ_STUB_REF_SHA="bbb333"
    TAGMAJ_STUB_WRITE_EXIT="0"
    echo "$TAGMAJ_STUB_REF_EXISTS" > "$TAGMAJ_STUB_EXISTS_FILE"
    export TAGMAJ_STUB_COUNTFILE TAGMAJ_STUB_WRITE_LOG TAGMAJ_STUB_EXISTS_FILE TAGMAJ_STUB_REPO_NAMEWITHOWNER \
        TAGMAJ_STUB_TAGS_JSON TAGMAJ_STUB_REF_EXISTS TAGMAJ_STUB_REF_SHA TAGMAJ_STUB_WRITE_EXIT
}

run_sut() {
    PATH="$WORK/bin:$PATH" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
    echo $?
}
write_calls() { wc -l < "$TAGMAJ_STUB_WRITE_LOG" | tr -d ' '; }

fake_gh

# Note: TAGMAJ_STUB_TAGS_JSON above is really tab-separated name/sha pairs,
# one per line, exactly what `gh api ... --jq '.[] | [.name,.commit.sha] |
# @tsv'` would print — the fake serves it verbatim so tag-major.sh's own
# parsing is what is under test, not a fake jq filter.

# Happy path, ref already exists: picks v1.10.0 (numeric, not lexical,
# sort), derives v1, PATCHes, read-back matches.
reset_scenario
rc="$(run_sut bash "$SUT" --repo test-owner/test-repo)"
check "happy path (existing ref): exits 0" 0 "$rc"
check "happy path: PATCHes exactly once" 1 "$(write_calls)"
check "happy path: writes to tags/v1" 1 "$(grep -c 'tags/v1$' "$TAGMAJ_STUB_WRITE_LOG")"
check "happy path: never POSTs" 0 "$(grep -c '^POST' "$TAGMAJ_STUB_WRITE_LOG")"
check "happy path: confirms the move" 1 "$(grep -c 'confirmed' "$WORK/stdout")"

# Ref does not exist yet (first release ever): must POST, not PATCH.
reset_scenario
echo false > "$TAGMAJ_STUB_EXISTS_FILE"
rc="$(run_sut bash "$SUT" --repo test-owner/test-repo)"
check "no existing ref: exits 0" 0 "$rc"
check "no existing ref: POSTs exactly once" 1 "$(grep -c '^POST' "$TAGMAJ_STUB_WRITE_LOG")"
check "no existing ref: never PATCHes" 0 "$(grep -c '^PATCH' "$TAGMAJ_STUB_WRITE_LOG")"

# The read-back must catch a write that reports success but did not land.
reset_scenario
TAGMAJ_STUB_REF_SHA="stale-sha-did-not-move"
export TAGMAJ_STUB_REF_SHA
rc="$(run_sut bash "$SUT" --repo test-owner/test-repo)"
check "read-back mismatch is a failure" 1 "$rc"
check "read-back mismatch is reported" 1 "$(grep -c 'FAILED' "$WORK/stderr")"

# The guard: refuse to move anything matching vN.Y.Z, even when asked to.
reset_scenario
rc="$(run_sut bash "$SUT" --repo test-owner/test-repo --major-tag v1.2.0)"
check "refuses moving a real version tag" 1 "$rc"
check "refuses with a 'refuse' message" 1 "$(grep -c 'refus' "$WORK/stderr")"
check "refusing a version tag never writes" 0 "$(write_calls)"

# No vX.Y.Z tags at all in the repo.
reset_scenario
TAGMAJ_STUB_TAGS_JSON=""
export TAGMAJ_STUB_TAGS_JSON
rc="$(run_sut bash "$SUT" --repo test-owner/test-repo)"
check "no version tags found is a failure" 1 "$rc"
check "no version tags found never writes" 0 "$(write_calls)"

# --dry-run decides and prints, but never writes.
reset_scenario
rc="$(run_sut bash "$SUT" --repo test-owner/test-repo --dry-run)"
check "--dry-run exits 0" 0 "$rc"
check "--dry-run never writes" 0 "$(write_calls)"
check "--dry-run still names the move" 1 "$(grep -c 'moving v1' "$WORK/stdout")"

rc="$(run_sut bash "$SUT" --help)"
check "--help exits 0" 0 "$rc"
check "--help prints usage" 1 "$(grep -c 'Usage:' "$WORK/stdout")"

rc="$(run_sut bash "$SUT" extra-arg)"
check "an unexpected positional is a usage error" 2 "$rc"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "tag-major-selftest.sh: FAILED"; exit 1; }
echo "tag-major-selftest.sh: all assertions passed"
