#!/usr/bin/env bash
#
# Selftest for release-publish.sh. Structurally offline: every case runs
# against a fake `gh` on PATH driven entirely by RELPUB_STUB_*/PRLAND_STUB_*/
# TAGMAJ_STUB_* environment variables. release-publish.sh execs the real
# pr-land.sh and tag-major.sh next to it, so this fake serves their calls
# too (keyed the same way each script's own selftest drives them). No
# assertion touches a network, a remote or a credential.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/release-publish.sh"
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

# fake_gh — one stand-in for every gh call release-publish.sh, pr-land.sh
# and tag-major.sh make, keyed on the --json field list or subcommand, so
# all three real scripts run unmodified underneath it.
fake_gh() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
count_file="$RELPUB_STUB_COUNTFILE"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    echo "$RELPUB_STUB_REPO_NAMEWITHOWNER"
    exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    echo "pr-list" >> "$RELPUB_STUB_PRLIST_LOG"
    printf '%s\n' "$RELPUB_STUB_PR_LIST_JSON"
    exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    case "$*" in
        *"headRefName,title,author"*)
            printf '%s\n' "$RELPUB_STUB_PR_VIEW_TSV"
            exit 0
            ;;
        *"state,mergeCommit"*)
            printf '%s\t%s\n' "$RELPUB_STUB_MERGE_STATE" "$RELPUB_STUB_MERGE_SHA"
            exit 0
            ;;
        *"--json state"*)
            echo "$PRLAND_STUB_FINAL_STATE"
            exit 0
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$PRLAND_STUB_BASE" "$PRLAND_STUB_SHA" "$PRLAND_STUB_IS_BOT" \
        "$PRLAND_STUB_LOGIN" "$PRLAND_STUB_PR_STATE"
    exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
    echo "$*" >> "$PRLAND_STUB_MERGE_LOG"
    exit "${PRLAND_STUB_MERGE_EXIT:-0}"
fi

if [ "$1" = "release" ] && [ "$2" = "view" ]; then
    echo "release-view" >> "$RELPUB_STUB_RELVIEW_LOG"
    n2=$(cat "$RELPUB_STUB_RELVIEW_LOG" | wc -l | tr -d ' ')
    [ "$n2" -ge "${RELPUB_STUB_RELEASE_OK_AFTER:-1}" ] && [ "$RELPUB_STUB_RELEASE_EVER_OK" = "true" ] && exit 0
    exit 1
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
        repos/*/rules/branches/*)
            printf '%s\n' "$PRLAND_STUB_REQUIRED"
            exit 0
            ;;
        repos/*/commits/*/check-runs)
            printf '%s\n' "$RELPUB_STUB_CHECKRUNS"
            exit 0
            ;;
        repos/*/tags)
            printf '%s\n' "$TAGMAJ_STUB_TAGS_JSON"
            exit 0
            ;;
        repos/*/git/ref/tags/*)
            if [ "$(cat "$TAGMAJ_STUB_EXISTS_FILE" 2>/dev/null)" = "true" ]; then
                body="$(printf '{"object":{"sha":"%s"}}' "$TAGMAJ_STUB_REF_SHA")"
                if [ -n "$jqfilter" ]; then printf '%s' "$body" | jq -r "$jqfilter"; else printf '%s\n' "$body"; fi
                exit 0
            fi
            echo "not found" >&2
            exit 1
            ;;
        repos/*/git/refs/tags/*)
            echo "PATCH $endpoint" >> "$TAGMAJ_STUB_WRITE_LOG"
            exit 0
            ;;
        repos/*/git/refs)
            echo "POST $endpoint" >> "$TAGMAJ_STUB_WRITE_LOG"
            echo true > "$TAGMAJ_STUB_EXISTS_FILE"
            exit 0
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

# reset_scenario — a green minor-release baseline: manifest 1.3.0, one open
# release-please PR computing 1.4.0, checks green, release present, v1
# already floating. Each test overrides only what it cares about.
reset_scenario() {
    REPO_DIR="$WORK/repo"
    mkdir -p "$REPO_DIR"
    echo '{".": "1.3.0"}' > "$REPO_DIR/.release-please-manifest.json"

    RELPUB_STUB_COUNTFILE="$WORK/count"
    RELPUB_STUB_PRLIST_LOG="$WORK/prlist.log"
    RELPUB_STUB_RELVIEW_LOG="$WORK/relview.log"
    PRLAND_STUB_MERGE_LOG="$WORK/merge.log"
    TAGMAJ_STUB_WRITE_LOG="$WORK/tagwrites.log"
    TAGMAJ_STUB_EXISTS_FILE="$WORK/ref-exists"
    : > "$RELPUB_STUB_COUNTFILE"
    : > "$RELPUB_STUB_PRLIST_LOG"
    : > "$RELPUB_STUB_RELVIEW_LOG"
    : > "$PRLAND_STUB_MERGE_LOG"
    : > "$TAGMAJ_STUB_WRITE_LOG"
    echo true > "$TAGMAJ_STUB_EXISTS_FILE"

    RELPUB_STUB_REPO_NAMEWITHOWNER="test-owner/test-repo"
    RELPUB_STUB_PR_LIST_JSON=$'50\trelease-please--branches--main\tchore(main): release 1.4.0'
    RELPUB_STUB_PR_VIEW_TSV=""
    RELPUB_STUB_MERGE_STATE="MERGED"
    RELPUB_STUB_MERGE_SHA="deadbeef"
    RELPUB_STUB_CHECKRUNS=$'completed\tsuccess'
    RELPUB_STUB_RELEASE_EVER_OK="true"
    RELPUB_STUB_RELEASE_OK_AFTER="1"

    PRLAND_STUB_BASE="main"
    PRLAND_STUB_SHA="deadbeef"
    PRLAND_STUB_IS_BOT="true"
    PRLAND_STUB_LOGIN="github-actions[bot]"
    PRLAND_STUB_PR_STATE="OPEN"
    PRLAND_STUB_REQUIRED=""
    PRLAND_STUB_MERGE_EXIT="0"
    PRLAND_STUB_FINAL_STATE="MERGED"

    TAGMAJ_STUB_TAGS_JSON=$'v1.3.0\tdeadbeef\nv1.4.0\tdeadbeef'
    TAGMAJ_STUB_REF_SHA="deadbeef"

    export RELPUB_STUB_COUNTFILE RELPUB_STUB_PRLIST_LOG RELPUB_STUB_RELVIEW_LOG \
        RELPUB_STUB_REPO_NAMEWITHOWNER RELPUB_STUB_PR_LIST_JSON RELPUB_STUB_PR_VIEW_TSV \
        RELPUB_STUB_MERGE_STATE RELPUB_STUB_MERGE_SHA RELPUB_STUB_CHECKRUNS \
        RELPUB_STUB_RELEASE_EVER_OK RELPUB_STUB_RELEASE_OK_AFTER \
        PRLAND_STUB_MERGE_LOG PRLAND_STUB_BASE PRLAND_STUB_SHA PRLAND_STUB_IS_BOT \
        PRLAND_STUB_LOGIN PRLAND_STUB_PR_STATE PRLAND_STUB_REQUIRED PRLAND_STUB_MERGE_EXIT \
        PRLAND_STUB_FINAL_STATE TAGMAJ_STUB_WRITE_LOG TAGMAJ_STUB_EXISTS_FILE \
        TAGMAJ_STUB_TAGS_JSON TAGMAJ_STUB_REF_SHA
}

run_sut() {
    (cd "$REPO_DIR" && PATH="$WORK/bin:$PATH" "$@" >"$WORK/stdout" 2>"$WORK/stderr")
    echo $?
}
merge_calls() { wc -l < "$PRLAND_STUB_MERGE_LOG" | tr -d ' '; }
prlist_calls() { wc -l < "$RELPUB_STUB_PRLIST_LOG" | tr -d ' '; }
tagwrite_calls() { wc -l < "$TAGMAJ_STUB_WRITE_LOG" | tr -d ' '; }

fake_gh

# Full happy path: minor level, one open release-please PR, bot merge
# (checks absent -> --admin), green CI, release present, major tag moved.
reset_scenario
rc="$(run_sut bash "$SUT" minor --repo test-owner/test-repo --wait-timeout-s 5)"
check "happy path (minor): exits 0" 0 "$rc"
check "happy path: merges exactly once" 1 "$(merge_calls)"
check "happy path: moves the major tag" 1 "$(tagwrite_calls)"
check "happy path: prints published" 1 "$(grep -c 'published minor release' "$WORK/stdout")"

# Major without --i-am-the-owner: refused before any gh call at all.
reset_scenario
rc="$(run_sut bash "$SUT" major --repo test-owner/test-repo)"
check "major without --i-am-the-owner: exits 1" 1 "$rc"
gh_calls="$(cat "$RELPUB_STUB_COUNTFILE" 2>/dev/null)"
check "major without --i-am-the-owner: touches no gh call" 0 "${gh_calls:-0}"
check "major without --i-am-the-owner: message names the flag" 1 "$(grep -c -- '--i-am-the-owner' "$WORK/stderr")"

# Major WITH --i-am-the-owner, computed as major: proceeds to completion.
reset_scenario
echo '{".": "1.9.5"}' > "$REPO_DIR/.release-please-manifest.json"
RELPUB_STUB_PR_LIST_JSON=$'51\trelease-please--branches--main\tchore(main): release 2.0.0'
export RELPUB_STUB_PR_LIST_JSON
TAGMAJ_STUB_TAGS_JSON=$'v1.9.5\tdeadbeef\nv2.0.0\tdeadbeef'
export TAGMAJ_STUB_TAGS_JSON
rc="$(run_sut bash "$SUT" major --repo test-owner/test-repo --i-am-the-owner --wait-timeout-s 5)"
check "major with --i-am-the-owner: exits 0" 0 "$rc"
check "major with --i-am-the-owner: merges once" 1 "$(merge_calls)"

# No open release-please PR found.
reset_scenario
RELPUB_STUB_PR_LIST_JSON=""
export RELPUB_STUB_PR_LIST_JSON
rc="$(run_sut bash "$SUT" minor --repo test-owner/test-repo)"
check "no open release-please PR: exits 1" 1 "$rc"
check "no open release-please PR: never merges" 0 "$(merge_calls)"

# Two open release-please PRs (a sibling package's PR is also open): refused.
reset_scenario
RELPUB_STUB_PR_LIST_JSON=$'50\trelease-please--branches--main--components--a\tchore(a): release 1.4.0\n51\trelease-please--branches--main--components--b\tchore(b): release 1.1.0'
export RELPUB_STUB_PR_LIST_JSON
rc="$(run_sut bash "$SUT" minor --repo test-owner/test-repo)"
check "two open release-please PRs: exits 1" 1 "$rc"
check "two open release-please PRs: never merges" 0 "$(merge_calls)"
check "two open release-please PRs: message says disambiguate" 1 "$(grep -c -- '--pr NUMBER' "$WORK/stderr")"

# --pr overrides discovery: gh pr list is never called.
reset_scenario
RELPUB_STUB_PR_VIEW_TSV=$'OPEN\trelease-please--branches--main\tchore(main): release 1.4.0\ttrue'
export RELPUB_STUB_PR_VIEW_TSV
rc="$(run_sut bash "$SUT" minor --repo test-owner/test-repo --pr 50 --wait-timeout-s 5)"
check "--pr override: exits 0" 0 "$rc"
check "--pr override: never calls pr list" 0 "$(prlist_calls)"

# Level mismatch: requested major, PR computes to minor. Refused before merging.
reset_scenario
rc="$(run_sut bash "$SUT" major --repo test-owner/test-repo --i-am-the-owner)"
check "level mismatch: exits 1" 1 "$rc"
check "level mismatch: never merges" 0 "$(merge_calls)"
check "level mismatch: names both levels" 1 "$(grep -c 'not major as requested' "$WORK/stderr")"

# --dry-run: decides and prints, merges and tags nothing.
reset_scenario
rc="$(run_sut bash "$SUT" minor --repo test-owner/test-repo --dry-run)"
check "--dry-run: exits 0" 0 "$rc"
check "--dry-run: never merges" 0 "$(merge_calls)"
check "--dry-run: never writes the tag" 0 "$(tagwrite_calls)"

# CI fails on the merge commit: caught, even though the PR is already merged.
reset_scenario
RELPUB_STUB_CHECKRUNS=$'completed\tfailure'
export RELPUB_STUB_CHECKRUNS
rc="$(run_sut bash "$SUT" minor --repo test-owner/test-repo --wait-timeout-s 5)"
check "CI failure on merge commit: exits 1" 1 "$rc"
check "CI failure on merge commit: never writes the tag" 0 "$(tagwrite_calls)"

# The release never appears: times out rather than hanging.
reset_scenario
RELPUB_STUB_RELEASE_EVER_OK="false"
export RELPUB_STUB_RELEASE_EVER_OK
rc="$(run_sut bash "$SUT" minor --repo test-owner/test-repo --wait-timeout-s 2)"
check "release never appears: exits 1 (times out)" 1 "$rc"
check "release never appears: never writes the tag" 0 "$(tagwrite_calls)"

rc="$(run_sut bash "$SUT" --help)"
check "--help exits 0" 0 "$rc"
check "--help prints usage" 1 "$(grep -c 'Usage:' "$WORK/stdout")"

rc="$(run_sut bash "$SUT")"
check "no level is a usage error" 2 "$rc"

rc="$(run_sut bash "$SUT" bogus-level)"
check "an invalid level is a usage error" 2 "$rc"

echo
echo "$((PASS + FAIL)) assertion(s), $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "release-publish-selftest.sh: FAILED"; exit 1; }
echo "release-publish-selftest.sh: all assertions passed"
