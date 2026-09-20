#!/usr/bin/env bash
#
# verify-run.sh — extract a ticket's `verify` frontmatter block and run it
# with the rules a hand-rolled runner keeps forgetting built in, instead of
# remembered:
#
#   - the block gates on EVERY line, not only its last one
#   - never traces the shell it runs
#   - runs against a worktree, not whatever a hardcoded `cd ~/code/<repo>`
#     line in the block happens to resolve to
#   - rejects a check that cannot fail (a `... || echo` fallback) before
#     running anything
#   - optionally proves the block is discriminating: it must FAIL at a base
#     ref, before the work exists, or it is not testing anything
#
# Usage:
#   verify-run.sh <ticket-file> [--root PATH] [--against REF] [--format text|json]
#
#   --root PATH     repo root the block runs against. Default: the toplevel
#                    of the git repo containing the current directory.
#   --against REF   first run the block in a scratch worktree checked out at
#                    REF; if it PASSES there, fail with a non-discriminating
#                    error instead of running the real check.
#   --format FORMAT  text (default) or json.
#
# Exit codes: 0 the block passed (and, with --against, correctly failed at
# the base ref first); 1 the block failed, was rejected as unfalsifiable, or
# passed at the base ref too; 2 a usage or setup error.

set -eu

TICKET=""
ROOT=""
AGAINST=""
FORMAT="text"

die_usage() { echo "verify-run.sh: $1" >&2; exit 2; }

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --root)
            [ $# -ge 2 ] || die_usage "--root needs a PATH"
            ROOT="$2"; shift 2 ;;
        --against)
            [ $# -ge 2 ] || die_usage "--against needs a REF"
            AGAINST="$2"; shift 2 ;;
        --format)
            [ $# -ge 2 ] || die_usage "--format needs text or json"
            FORMAT="$2"; shift 2 ;;
        --) shift; break ;;
        -*) die_usage "unknown option: $1" ;;
        *)
            [ -z "$TICKET" ] || die_usage "unexpected extra argument: $1"
            TICKET="$1"; shift ;;
    esac
done

[ -n "$TICKET" ] || { usage >&2; exit 2; }
[ -f "$TICKET" ] || die_usage "ticket file not found: $TICKET"

case "$FORMAT" in
    text|json) ;;
    *) die_usage "--format must be text or json, got: $FORMAT" ;;
esac

# extract_verify_block FILE — the `verify: |` frontmatter block scalar's own
# text, dedented. Stops at the first line less indented than the block's
# own first content line, or at the closing `---`, whichever comes first.
extract_verify_block() {
    awk '
        /^---[[:space:]]*$/ { fmcount++; if (fmcount == 2) exit; next }
        fmcount != 1 { next }
        /^verify:[[:space:]]*[|]/ { capturing = 1; base = -1; next }
        capturing {
            if ($0 ~ /^[[:space:]]*$/) {
                if (base < 0) next
                print ""
                next
            }
            match($0, /^[ ]*/)
            ind = RLENGTH
            if (base < 0) base = ind
            if (ind < base) exit
            print substr($0, base + 1)
        }
    ' "$1"
}

BLOCK="$(extract_verify_block "$TICKET")"
[ -n "$BLOCK" ] || die_usage "no verify block found in $TICKET"

# reject_unfalsifiable BLOCK — a line whose command chain ends in
# `|| echo ...` always exits 0, so a runner that executes it proves nothing.
# Quoted text is stripped first so a check that greps FOR that idiom (as
# this project's own tickets do) is not mistaken for the idiom itself.
reject_unfalsifiable() {
    local ln stripped
    while IFS= read -r ln; do
        stripped="$(printf '%s' "$ln" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"
        if printf '%s' "$stripped" | grep -Eq '\|\|[[:space:]]*echo([[:space:]]|$)'; then
            printf '%s' "$ln"
            return 0
        fi
    done <<<"$1"
    return 1
}

BAD_LINE="$(reject_unfalsifiable "$BLOCK" || true)"
if [ -n "$BAD_LINE" ]; then
    echo "verify-run.sh: rejected — unfalsifiable check (a '|| echo' fallback always exits 0):" >&2
    echo "  $BAD_LINE" >&2
    [ "$FORMAT" = json ] && print_json fail null "unfalsifiable check: $BAD_LINE"
    exit 1
fi

if [ -z "$ROOT" ]; then
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
        || die_usage "--root not given and the current directory is not inside a git repo"
fi
[ -d "$ROOT" ] || die_usage "--root path does not exist: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

# strip_leading_cd BLOCK — drops the block's own first `cd ...` line, if it
# has one, so the caller can substitute its own without running two.
strip_leading_cd() {
    awk '
        !seen && /^[[:space:]]*$/ { print; next }
        !seen { seen = 1; if ($0 ~ /^[[:space:]]*cd[[:space:]]/) next }
        { print }
    ' <<<"$1"
}

# run_block ROOT BLOCK — writes BLOCK to a temp script, rooted at ROOT, and
# runs it. `set -e` (no pipefail) makes every line gate the result on its
# own exit status; pipefail is deliberately left off because this project's
# own verify blocks rely on `producer | grep -q pattern` gating on grep's
# exit status, and pipefail would misreport that as failed on a producer's
# SIGPIPE when grep matches early. No trace flag is ever set.
run_block() {
    local root="$1" block="$2" tmp rc
    tmp="$(mktemp)"
    {
        cat <<'HDR'
#!/usr/bin/env bash
set -eu
trap 'ec=$?; printf "verify-run: FAILED (exit %d): %s\n" "$ec" "$BASH_COMMAND" >&2; exit "$ec"' ERR
HDR
        printf 'cd %q\n' "$root"
        printf '%s\n' "$(strip_leading_cd "$block")"
    } > "$tmp"
    chmod +x "$tmp"
    bash "$tmp"
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

print_json() {
    local result="$1" against="$2" message="$3" ag
    if [ "$against" = "null" ] || [ -z "$against" ]; then
        ag="null"
    else
        ag="\"$(json_escape "$against")\""
    fi
    printf '{"ticket":"%s","root":"%s","against":%s,"result":"%s","message":"%s"}\n' \
        "$(json_escape "$TICKET")" "$(json_escape "$ROOT")" "$ag" "$result" "$(json_escape "$message")"
}

# run_against_check REPO REF BLOCK — runs BLOCK in a scratch worktree checked
# out at REF and leaves its exit status in AGAINST_RC. The scratch worktree
# always lives under a fresh mktemp -d, never inside REPO.
run_against_check() {
    local repo="$1" ref="$2" block="$3" parent scratch rc
    parent="$(mktemp -d)"
    scratch="$parent/wt"
    if ! git -C "$repo" worktree add --detach "$scratch" "$ref" >/dev/null 2>"$parent/err"; then
        echo "verify-run.sh: could not create a scratch worktree at $ref:" >&2
        sed 's/^/  /' "$parent/err" >&2
        rm -rf "$parent"
        exit 2
    fi
    set +e
    run_block "$scratch" "$block"
    rc=$?
    set -e
    git -C "$repo" worktree remove --force "$scratch" >/dev/null 2>&1 || true
    rm -rf "$parent"
    AGAINST_RC=$rc
}

if [ -n "$AGAINST" ]; then
    AGAINST_RC=1
    run_against_check "$ROOT" "$AGAINST" "$BLOCK"
    if [ "$AGAINST_RC" -eq 0 ]; then
        echo "verify-run.sh: FAIL — this block also passes at $AGAINST, before the work exists (non-discriminating)" >&2
        [ "$FORMAT" = json ] && print_json fail "$AGAINST" "non-discriminating: block passed at base ref"
        exit 1
    fi
    echo "verify-run.sh: ok — block fails at $AGAINST as expected (discriminating)"
fi

set +e
run_block "$ROOT" "$BLOCK"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
    echo "verify-run.sh: PASS — $TICKET"
    [ "$FORMAT" = json ] && print_json pass "${AGAINST:-null}" ""
    exit 0
fi

echo "verify-run.sh: FAIL — $TICKET (exit $RC)" >&2
[ "$FORMAT" = json ] && print_json fail "${AGAINST:-null}" "block exited $RC"
exit 1
