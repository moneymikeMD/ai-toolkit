#!/bin/bash
#
# land-core.sh — merge finished branches onto a target branch and push, through
# a dedicated integration worktree. The generic half of a "land a ticket"
# script: no tickets, trackers or multiplexers; a consumer supplies those
# through one hook script.
#
# Usage:
#   land-core.sh --repo PATH --branch NAME
#                [--target BRANCH] [--label TEXT] [--merge-message MSG]
#                [--lint-cmd CMD] [--hook PATH] [--reset-land] [--dry-run]
#                [--allow-untracked PATH]...
#   land-core.sh --repo PATH --item BRANCH[:LABEL]... [--target BRANCH]
#                [--lint-cmd CMD] [--hook PATH] [--reset-land] [--dry-run] ...
#   land-core.sh --help
#
# --repo is MANDATORY with no cwd fallback: this merges, pushes and deletes a
# branch, and a cwd default would pick whichever repo the caller stood in.
# Merge, lint and push run in `<parent-of-main-worktree>/<basename>-land`,
# reset to origin/<target> every run; a dirty one is refused without
# --reset-land; a concurrent run is refused by `<worktree>.lock`, never waited
# on. The main worktree is NOT fast-forwarded; the summary prints the pull.
#
# HOOKS. --hook PATH is called as `PATH <point>`, cwd the integration worktree:
#   pre-merge   synced, nothing merged; may commit (pushed with the merge).
#               Non-zero: reset to origin/<target>, exit 2.
#   post-merge  merge commit exists, lint not run. Non-zero: reverted, exit 1.
#   pre-push    lint passed; may commit (pushed). Non-zero: reverted, exit 1.
#   post-push   pushed (or no remote); never reverted. Non-zero: cleanup still
#               runs, exit 1.
# Exit 0 from an unhandled point. Context is env, not argv: LAND_CORE_POINT,
# LAND_CORE_REPO (main worktree), LAND_CORE_WORKTREE, LAND_CORE_BRANCH,
# LAND_CORE_TARGET, LAND_CORE_LABEL, LAND_CORE_MERGE_SHA (empty before the
# merge), LAND_CORE_PUSHED (post-push: 1 pushed, 0 no remote).
#
# --allow-untracked PATH (repeatable) exempts one exact untracked entry,
# relative to the branch worktree root and matched byte for byte, from its
# dirty check; when it is all that is there, cleanup removes with --force.
# --dry-run calls NO hook and mutates nothing, not even the worktree.
#
# Exit codes: 0 landed. 1 failed after the merge (post-merge hook, lint,
# pre-push hook: reverted with `reset --hard ORIG_HEAD`, so a pre-merge hook
# commit survives unpushed), or the push or post-push hook failed (NOT
# reverted). 2 stopped early (input, dirty tree, conflict, git precondition,
# pre-merge refusal); nothing pushed.
#
# Env (the flag wins): LAND_CORE_TARGET_BRANCH (default main), LAND_CORE_HOOK,
# LAND_CORE_LINT_CMD (default ./scripts/lint.sh in the merged tree if
# executable, else skipped with a warning). The lint runs through `bash -c`.
#
# BATCH (--item; after homelab LAB-652; refuses --branch/--label/
# --merge-message): one lock, items merged --no-ff in order (LABEL prefixes the
# subject), ONE lint, ONE push, never retried. A red lint is bisected to the
# first failing prefix, at most LAND_CORE_BATCH_MAX_LINTS runs (default 16).
# Hooks: pre-merge, pre-push once (LAND_CORE_BRANCH empty); post-merge never;
# post-push per landed item. All get LAND_CORE_BATCH=1 and LAND_CORE_ITEMS
# (`BRANCH<TAB>LABEL` per item still in the train). Last output, one row each:
#   Batch result:
#     <fate> <branch>[ [<label>]]  <sha7|->[  <note>]   (fate left-justified
#     to 18; fields 1 and 2 are fate and branch, as branch names hold no space)
# Fates: landed (merged, linted, pushed); post-push-failed (landed, its hook
#   failed); refused (dirty worktree, already on target, or pre-merge hook
#   refusal); conflict-skipped (merge conflicted); lint-dropped (bisected
#   culprit); dependent-dropped (holds a non-landing item's commits);
#   base-red (lint red with nothing merged, none blamed); lint-unresolved (lint
#   budget spent); pre-push-refused (hook refused); push-failed (the push
#   failed; merges kept local in the integration worktree, branches kept).
# Exit: 0 every item landed. 3 some landed (landed or post-push-failed), some
#   not. 1 none landed and a merge was made (base-red, lint-dropped,
#   lint-unresolved, pre-push-refused, push-failed, or a git failure mid-train).
#   2 none landed, nothing reached lint (input, pre-merge hook, or only
#   refused/conflict-skipped/dependent-dropped).
set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/kit.sh"

TARGET_BRANCH="${LAND_CORE_TARGET_BRANCH:-main}"
LINT_CMD="${LAND_CORE_LINT_CMD:-}"
HOOK="${LAND_CORE_HOOK:-}"
REPO_ARG=""
BRANCH=""
LABEL=""
MERGE_MSG_ARG=""
RESET_LAND=0
DRY_RUN=0
ALLOW_UNTRACKED=()
ITEMS_RAW=()
MAX_LINTS="${LAND_CORE_BATCH_MAX_LINTS:-16}"

# This script never sets a trap: kit.sh keeps the one EXIT handler, so every
# controlled exit path releases the lock explicitly instead.
LAND_LOCK_FILE=""
LAND_LOCK_ACQUIRED=0

# release_land_lock — best-effort; a failure warns rather than exits, because
# the next run's stale-pid reclaim recovers an orphaned lock.
release_land_lock() {
    [ "$LAND_LOCK_ACQUIRED" = 1 ] || return 0
    [ -n "$LAND_LOCK_FILE" ] || return 0
    LAND_LOCK_ACQUIRED=0
    rm -f "$LAND_LOCK_FILE" 2>/dev/null \
        || warn "could not remove lock file '$LAND_LOCK_FILE' — remove it by hand once no land-core.sh run is using it"
}

# stop2 MESSAGE... — a precondition failed and nothing was pushed. Exit 2.
stop2() { release_land_lock; echo "Error: $*" >&2; exit 2; }

# reset_to_origin — undo whatever a pre-merge hook committed. Used only
# before the merge, where origin/<target> is the exact starting state.
reset_to_origin() {
    git reset --hard "origin/$TARGET_BRANCH" >/dev/null 2>&1 \
        || warn "could not reset to origin/$TARGET_BRANCH — the next run's sync will"
}

# revert_merge — put $TARGET_BRANCH back where the merge found it.
revert_merge() {
    git reset --hard ORIG_HEAD >/dev/null 2>&1 \
        || warn "git reset --hard ORIG_HEAD failed — the integration worktree may still carry the merge commit, check by hand"
}

stop2_reset() { release_land_lock; revert_merge; echo "Error: $*" >&2; exit 2; }
die_reset()   { release_land_lock; revert_merge; die "$*"; }

# acquire_land_lock FILE — never waits: wins the lock, or refuses naming the
# holder's pid. A holder whose pid is not running is reclaimed and retried.
acquire_land_lock() {
    local file="$1" attempt=0 tmp holder_pid holder_started
    LAND_LOCK_FILE="$file"
    while [ "$attempt" -lt 20 ]; do
        attempt=$((attempt + 1))
        tmp="$file.holder.$$"
        printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$tmp" \
            || stop2 "could not write a temp lock-holder file '$tmp'"
        if ln "$tmp" "$file" 2>/dev/null; then
            rm -f "$tmp"
            LAND_LOCK_ACQUIRED=1
            return 0
        fi
        rm -f "$tmp"
        holder_pid=""
        holder_started=""
        if [ -f "$file" ]; then
            holder_pid=$(awk -F= '/^pid=/{print $2}' "$file" 2>/dev/null)
            holder_started=$(awk -F= '/^started=/{print $2}' "$file" 2>/dev/null)
        fi
        case "$holder_pid" in ''|*[!0-9]*) holder_pid="" ;; esac
        if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
            stop2 "integration worktree '$LAND_WORKTREE' is locked by pid $holder_pid (started epoch $holder_started) — another land-core.sh run holds it. Wait for it, or remove '$file' by hand if you are certain that pid is not land-core.sh"
        fi
        rm -f "$file" 2>/dev/null
    done
    stop2 "could not acquire the integration worktree lock '$file' after $attempt attempts — repeatedly lost the race, or could not create/remove it (permissions?)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --dry-run) DRY_RUN=1; shift ;;
        --reset-land) RESET_LAND=1; shift ;;
        --repo)
            [ $# -ge 2 ] || stop2 "--repo needs a path"
            REPO_ARG="$2"; shift 2 ;;
        --branch)
            [ $# -ge 2 ] || stop2 "--branch needs a branch name"
            BRANCH="$2"; shift 2 ;;
        --target)
            [ $# -ge 2 ] || stop2 "--target needs a branch name"
            TARGET_BRANCH="$2"; shift 2 ;;
        --label)
            [ $# -ge 2 ] || stop2 "--label needs text"
            LABEL="$2"; shift 2 ;;
        --merge-message)
            [ $# -ge 2 ] || stop2 "--merge-message needs text"
            MERGE_MSG_ARG="$2"; shift 2 ;;
        --lint-cmd)
            [ $# -ge 2 ] || stop2 "--lint-cmd needs a command"
            LINT_CMD="$2"; shift 2 ;;
        --hook)
            [ $# -ge 2 ] || stop2 "--hook needs a path"
            HOOK="$2"; shift 2 ;;
        --allow-untracked)
            [ $# -ge 2 ] && [ -n "$2" ] || stop2 "--allow-untracked needs a path"
            ALLOW_UNTRACKED+=("${2#./}"); shift 2 ;;
        --item)
            [ $# -ge 2 ] || stop2 "--item needs BRANCH[:LABEL]"
            ITEMS_RAW+=("$2"); shift 2 ;;
        -*) stop2 "unknown option: $1 (see --help)" ;;
        *)  stop2 "unexpected positional argument '$1' — every input is a flag (see --help)" ;;
    esac
done

need git

[ -n "$REPO_ARG" ] || stop2 "--repo PATH is required and has no cwd default — name the repository to land in"
[ -d "$REPO_ARG" ] || stop2 "--repo '$REPO_ARG' is not a directory"
BATCH=0
if [ "${#ITEMS_RAW[@]}" -gt 0 ]; then
    BATCH=1
    [ -z "$BRANCH" ] || stop2 "--branch and --item cannot be combined — a batch names every branch with --item"
    [ -z "$LABEL" ] || stop2 "--label cannot be combined with --item — give each item its label as BRANCH:LABEL"
    [ -z "$MERGE_MSG_ARG" ] || stop2 "--merge-message cannot be combined with --item — each item's merge subject is built from its label"
    case "$MAX_LINTS" in ''|*[!0-9]*|0) stop2 "LAND_CORE_BATCH_MAX_LINTS must be a positive integer, got '$MAX_LINTS'" ;; esac
fi
[ "$BATCH" = 1 ] || [ -n "$BRANCH" ] || stop2 "--branch NAME is required"
[ -n "$TARGET_BRANCH" ] || stop2 "--target must not be empty"
LF=$'\n'
case "$LABEL" in *"$LF"*) stop2 "--label must not contain a newline — it becomes the merge subject's prefix" ;; esac

if [ -n "$HOOK" ]; then
    [ -x "$HOOK" ] || stop2 "--hook '$HOOK' is missing or not executable"
    case "$HOOK" in
        /*) ;;
        *) HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")" ;;
    esac
fi

REPO_TOP=$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null) \
    || stop2 "--repo '$REPO_ARG' is not inside a git repository"

if [ "$BATCH" = 0 ]; then
    git -C "$REPO_TOP" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
        || stop2 "branch '$BRANCH' does not exist in '$REPO_TOP'"
fi

# A real `git worktree list` failure swallowed into "" is indistinguishable
# from "no worktrees", so it stops here rather than being guessed past.
if ! WT_PORCELAIN=$(git -C "$REPO_TOP" worktree list --porcelain 2>&1); then
    stop2 "could not evaluate 'git worktree list' in '$REPO_TOP': $WT_PORCELAIN"
fi
MAIN_WORKTREE=$(printf '%s\n' "$WT_PORCELAIN" | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
[ -n "$MAIN_WORKTREE" ] || stop2 "could not determine the main worktree of '$REPO_TOP'"
LAND_WORKTREE="$(dirname "$MAIN_WORKTREE")/$(basename "$MAIN_WORKTREE")-land"
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

# branch_wt_check BRANCH — sets BWT to the branch's worktree ("" if none) and
# BWT_FORCE to --force when only allowed untracked files are there. Returns 1
# with BWT_ERR set when that worktree is dirty or cannot be read.
branch_wt_check() {
    local br="$1" entry allowed only_allowed=0 dirty="" rc=""
    BWT_ERR=""
    BWT_FORCE=""
    BWT=$(printf '%s\n' "$WT_PORCELAIN" | awk -v b="refs/heads/$br" '
        /^worktree / { path=$0; sub(/^worktree /,"",path) }
        /^branch /   { br=$0; sub(/^branch /,"",br); if (br==b) print path }
    ')
    [ -n "$BWT" ] || return 0
    # -z, so a path with a space or non-ASCII byte arrives unquoted; -uall, so
    # a file in an untracked directory is listed by itself rather than
    # collapsed into `?? dir/`, which no allowed path could match. Process
    # substitution loses git's exit status, so it travels as a final record.
    while IFS= read -r -d '' entry; do
        case "$entry" in
            "") continue ;;
            "land-core-status-rc="*) rc="${entry#land-core-status-rc=}"; continue ;;
            "?? "*)
                for allowed in ${ALLOW_UNTRACKED[@]+"${ALLOW_UNTRACKED[@]}"}; do
                    if [ "${entry#\?\? }" = "$allowed" ]; then
                        only_allowed=1
                        continue 2
                    fi
                done ;;
        esac
        dirty="${dirty}${entry}
"
    done < <(rc=0; git -C "$BWT" status --porcelain -z --untracked-files=all 2>&1 || rc=$?; printf '\0land-core-status-rc=%s\0' "$rc")
    if [ "$rc" != 0 ]; then
        BWT_ERR="could not check worktree '$BWT' for branch '$br' (removed or corrupt worktree?): $dirty"
        return 1
    fi
    if [ -n "$dirty" ]; then
        BWT_ERR="branch '$br' worktree at '$BWT' has uncommitted changes — commit or stash them first"
        return 1
    fi
    [ "$only_allowed" = 0 ] || BWT_FORCE="--force"
    return 0
}

BRANCH_WT=""
WT_RM_FORCE=""
if [ "$BATCH" = 0 ]; then
    branch_wt_check "$BRANCH" || stop2 "$BWT_ERR"
    BRANCH_WT="$BWT"
    WT_RM_FORCE="$BWT_FORCE"
fi

MERGE_MSG="$MERGE_MSG_ARG"
[ -n "$MERGE_MSG" ] || MERGE_MSG="${LABEL:+$LABEL: }merge branch '$BRANCH' into $TARGET_BRANCH

Landed via land-core.sh."

MERGE_SHA=""
PUSHED=0
POST_PUSH_FAILED=""

# run_hook POINT — call the hook script with its context. Returns the hook's
# exit code; callers decide what that means at their point.
run_hook() {
    [ -n "$HOOK" ] || return 0
    echo "hook: $HOOK $1"
    LAND_CORE_POINT="$1" \
    LAND_CORE_REPO="$MAIN_WORKTREE" \
    LAND_CORE_WORKTREE="$LAND_WORKTREE" \
    LAND_CORE_BRANCH="$BRANCH" \
    LAND_CORE_TARGET="$TARGET_BRANCH" \
    LAND_CORE_LABEL="$LABEL" \
    LAND_CORE_MERGE_SHA="$MERGE_SHA" \
    LAND_CORE_PUSHED="$PUSHED" \
        "$HOOK" "$1"
}

# cleanup_branch BRANCH WORKTREE FORCE — remove the branch's worktree (if any,
# and not the main one) and delete the branch, warning on each refusal.
cleanup_branch() {
    local br="$1" wt="$2" force="$3" out
    if [ -n "$wt" ] && [ "$wt" != "$MAIN_WORKTREE" ] && [ -e "$wt" ]; then
        case "$(pwd -P)/" in
            "$wt"/*) warn "worktree '$wt' holds branch '$br' but this script is running inside it — left in place" ;;
            *)
                # --force only when the dirty check proved the worktree holds
                # nothing but allowed files; anything else still refuses here.
                if out=$(git -C "$MAIN_WORKTREE" worktree remove ${force:+"$force"} "$wt" 2>&1); then
                    echo "removed worktree '$wt'."
                else
                    warn "could not remove worktree '$wt' — left in place: $out"
                fi
                ;;
        esac
    fi
    # Run from the integration worktree, whose HEAD carries the merge: `git
    # branch -d` refuses a branch not merged into the HEAD it is run against,
    # and the main worktree is deliberately left un-fast-forwarded.
    if git branch -d "$br" >/dev/null 2>&1; then
        echo "deleted local branch '$br'."
    else
        warn "could not delete local branch '$br' — left in place"
    fi
}

# Batch item state, one index per --item: branch, label, tip sha, fate,
# merge sha, note, branch worktree, worktree-remove force flag.
IB=(); IL=(); IT=(); IFATE=(); IS=(); IN=(); IW=(); IWF=()
NI=0
SURV=()
BASE_SHA=""
LINTS=0

batch_preflight() {
    local raw br label i j
    for raw in "${ITEMS_RAW[@]}"; do
        br="${raw%%:*}"
        label=""
        case "$raw" in *:*) label="${raw#*:}" ;; esac
        [ -n "$br" ] || stop2 "--item '$raw' has no branch name — the form is BRANCH[:LABEL]"
        case "$label" in *"$LF"*) stop2 "--item '$br' label must not contain a newline — it becomes the merge subject's prefix" ;; esac
        for ((j = 0; j < NI; j++)); do
            [ "${IB[j]}" != "$br" ] || stop2 "--item '$br' is listed twice"
        done
        IT[NI]=$(git -C "$REPO_TOP" rev-parse --verify --quiet "refs/heads/$br^{commit}") \
            || stop2 "branch '$br' does not exist in '$REPO_TOP' — nothing in the batch was touched"
        IB[NI]="$br"; IL[NI]="$label"; IFATE[NI]=pending; IS[NI]=""; IN[NI]=""; IW[NI]=""; IWF[NI]=""
        NI=$((NI + 1))
    done
    for ((i = 0; i < NI; i++)); do
        if branch_wt_check "${IB[i]}"; then
            IW[i]="$BWT"; IWF[i]="$BWT_FORCE"
        else
            IFATE[i]=refused; IN[i]="$BWT_ERR"
        fi
    done
}

batch_plan() {
    local i
    echo "Plan (batch of $NI):"
    echo "  0. integration worktree: '$LAND_WORKTREE' ($LAND_STATE_DESC)"
    echo "  1. hook pre-merge, once${HOOK:+ ($HOOK)}"
    echo "  2. merge train onto '$TARGET_BRANCH', --no-ff, in this order (a conflict is skipped):"
    for ((i = 0; i < NI; i++)); do
        if [ "${IFATE[i]}" = pending ]; then
            echo "       ${IB[i]}${IL[i]:+ (label: ${IL[i]})}"
        else
            echo "       ${IB[i]} — ${IFATE[i]}: ${IN[i]}"
        fi
    done
    echo "  3. lint the train once: $LINT_PREVIEW; on failure, bisect to the culprit and relint (at most $MAX_LINTS lint runs)"
    echo "  4. hook pre-push, once${HOOK:+ ($HOOK)}"
    echo "  5. git push origin HEAD:$TARGET_BRANCH, once (from the integration worktree; '$MAIN_WORKTREE' is not fast-forwarded automatically)"
    echo "  6. per landed item: hook post-push${HOOK:+ ($HOOK)}, then remove its worktree and git branch -d"
    [ -n "$HOOK" ] || echo "  (no --hook given — every hook step is a no-op)"
}

batch_set_items_env() {
    local i lines=""
    for ((i = 0; i < NI; i++)); do
        [ "${IFATE[i]}" = pending ] || continue
        lines="${lines}${IB[i]}	${IL[i]}
"
    done
    export LAND_CORE_ITEMS="$lines"
}

collect_survivors() {
    local i
    SURV=()
    for ((i = 0; i < NI; i++)); do
        [ "${IFATE[i]}" != pending ] || SURV+=("$i")
    done
}

# drop_dependents — an item whose branch contains the unlanded commits of an
# item that will not land would push those commits anyway, so it goes too.
drop_dependents() {
    local i j
    for ((i = 0; i < NI; i++)); do
        [ "${IFATE[i]}" = pending ] || continue
        for ((j = 0; j < NI; j++)); do
            [ "$j" != "$i" ] || continue
            case "${IFATE[j]}" in pending|landed) continue ;; esac
            git merge-base --is-ancestor "${IT[j]}" "$BASE_SHA" 2>/dev/null && continue
            if git merge-base --is-ancestor "${IT[j]}" "${IT[i]}" 2>/dev/null; then
                IFATE[i]=dependent-dropped
                IN[i]="contains the unlanded commits of '${IB[j]}' (${IFATE[j]})"
                break
            fi
        done
    done
}

# merge_item I — merge one item onto HEAD. Returns 1 (HEAD unchanged, IN set)
# when it cannot merge cleanly.
merge_item() {
    local i="$1" pre out conflicts msg
    pre=$(git rev-parse HEAD)
    IS[i]=""
    if git merge-base --is-ancestor "${IT[i]}" HEAD 2>/dev/null; then
        IN[i]="no merge commit of its own: it came in with an earlier merge in this batch"
        return 0
    fi
    msg="${IL[i]:+${IL[i]}: }merge branch '${IB[i]}' into $TARGET_BRANCH

Landed via land-core.sh."
    if ! out=$(git merge --no-ff "${IT[i]}" -m "$msg" 2>&1); then
        conflicts=$(git diff --name-only --diff-filter=U 2>&1) || conflicts="(could not list conflicting files: $conflicts)"
        git merge --abort >/dev/null 2>&1 || true
        git reset --hard "$pre" >/dev/null 2>&1 || warn "could not reset to $pre after a failed merge of '${IB[i]}'"
        if [ -n "$conflicts" ]; then
            IN[i]="merge conflict, aborted. Conflicting file(s): $(printf '%s' "$conflicts" | tr '\n' ' ')"
        else
            IN[i]="git merge failed, not a content conflict: $(printf '%s' "$out" | tr '\n' ' ')"
        fi
        return 1
    fi
    if ! conflicts=$(git diff --name-only --diff-filter=U 2>&1) || [ -n "$conflicts" ]; then
        git reset --hard "$pre" >/dev/null 2>&1 || true
        IN[i]="merge reported success but left unmerged paths: $(printf '%s' "$conflicts" | tr '\n' ' ')"
        return 1
    fi
    IS[i]=$(git rev-parse HEAD)
    IN[i]=""
    return 0
}

# build_train [LIMIT] — reset to BASE_SHA and merge the first LIMIT survivors
# (all of them by default). A conflict marks the item and drops dependents.
build_train() {
    local limit="${1:-0}" n=0 i
    git reset --hard "$BASE_SHA" >/dev/null 2>&1 || batch_die "could not reset the integration worktree to the batch base $BASE_SHA — nothing pushed"
    collect_survivors
    for i in ${SURV[@]+"${SURV[@]}"}; do
        [ "$limit" = 0 ] || [ "$n" -lt "$limit" ] || break
        [ "${IFATE[i]}" = pending ] || continue
        if merge_item "$i"; then
            n=$((n + 1))
        else
            IFATE[i]=conflict-skipped
            echo "conflict-skipped '${IB[i]}': ${IN[i]}" >&2
            drop_dependents
        fi
    done
    collect_survivors
}

# lint_tree WHAT — 0 clean, 1 red, 2 the lint budget is spent.
lint_tree() {
    if [ "$LINTS" -ge "$MAX_LINTS" ]; then
        return 2
    fi
    LINTS=$((LINTS + 1))
    echo "Running $EFFECTIVE_LINT on $1 (lint run $LINTS of at most $MAX_LINTS)..."
    if bash -c "$EFFECTIVE_LINT"; then
        echo "lint: clean."
        return 0
    fi
    echo "lint: red on $1." >&2
    return 1
}

# mark_pending FATE NOTE — every item still in the train gets FATE.
mark_pending() {
    local i
    for ((i = 0; i < NI; i++)); do
        [ "${IFATE[i]}" = pending ] || continue
        IFATE[i]="$1"; IN[i]="$2"
    done
}

# batch_die MESSAGE — a git step failed mid-batch: put the integration worktree
# back on the batch base, release the lock, exit 1. Nothing was pushed.
batch_die() {
    if [ -n "$BASE_SHA" ]; then
        git reset --hard "$BASE_SHA" >/dev/null 2>&1 \
            || warn "could not reset to the batch base $BASE_SHA — the integration worktree may carry merges, the next run's sync discards them"
    fi
    release_land_lock
    die "$*"
}

batch_table() {
    local i sha
    echo
    echo "Batch result:"
    for ((i = 0; i < NI; i++)); do
        sha="${IS[i]:0:7}"
        printf '  %-18s %s%s  %s%s\n' "${IFATE[i]}" "${IB[i]}" "${IL[i]:+ [${IL[i]}]}" "${sha:--}" "${IN[i]:+  ${IN[i]}}"
    done
}

# batch_finish — print the table, release the lock and exit with the batch
# code: 0 all landed, 3 partial, 1 nothing landed after a merge, 2 otherwise.
batch_finish() {
    local i landed=0 clean=0 post_merge_fate=0
    for ((i = 0; i < NI; i++)); do
        case "${IFATE[i]}" in
            landed) landed=$((landed + 1)); clean=$((clean + 1)) ;;
            post-push-failed) landed=$((landed + 1)) ;;
            lint-dropped|base-red|lint-unresolved|pre-push-refused|push-failed) post_merge_fate=1 ;;
        esac
    done
    batch_table
    if [ "$landed" = 0 ]; then
        git reset --hard "$BASE_SHA" >/dev/null 2>&1 \
            || warn "could not reset to the batch base $BASE_SHA — the next run's sync discards what is left"
    fi
    release_land_lock
    if [ "$clean" = "$NI" ]; then
        echo "batch: all $NI item(s) landed on '$TARGET_BRANCH'."
        exit 0
    fi
    if [ "$landed" -gt 0 ]; then
        echo "batch: $landed of $NI item(s) landed on '$TARGET_BRANCH'; the table above names what did not, or what is unfinished." >&2
        exit 3
    fi
    echo "Error: batch: nothing landed on '$TARGET_BRANCH', nothing pushed." >&2
    [ "$post_merge_fate" = 0 ] || exit 1
    exit 2
}

batch_main() {
    local rc lo hi mid culprit n i
    export LAND_CORE_BATCH=1
    BRANCH=""; LABEL=""; MERGE_SHA=""
    batch_set_items_env
    rc=0
    run_hook pre-merge || rc=$?
    if [ "$rc" != 0 ]; then
        reset_to_origin
        mark_pending refused "the pre-merge hook refused (exit $rc)"
        batch_table
        stop2 "the pre-merge hook refused (exit $rc) — nothing merged, nothing pushed"
    fi
    BASE_SHA=$(git rev-parse HEAD) || batch_die "could not read the integration worktree HEAD after the pre-merge hook — nothing pushed"
    for ((i = 0; i < NI; i++)); do
        [ "${IFATE[i]}" = pending ] || continue
        if git merge-base --is-ancestor "${IT[i]}" "$BASE_SHA" 2>/dev/null; then
            IFATE[i]=refused; IN[i]="already on $TARGET_BRANCH — nothing to land"
        fi
    done
    drop_dependents

    echo
    echo "Building the merge train on $BASE_SHA..."
    build_train
    EFFECTIVE_LINT="$LINT_CMD"
    if [ -z "$EFFECTIVE_LINT" ] && [ -x ./scripts/lint.sh ]; then
        EFFECTIVE_LINT="./scripts/lint.sh"
    fi
    [ -n "$EFFECTIVE_LINT" ] || warn "no lint command configured (--lint-cmd / \$LAND_CORE_LINT_CMD) and no executable ./scripts/lint.sh in the merged tree — skipping"

    while [ -n "$EFFECTIVE_LINT" ] && [ "${#SURV[@]}" -gt 0 ]; do
        n="${#SURV[@]}"
        rc=0; lint_tree "the train of $n" || rc=$?
        [ "$rc" != 0 ] || break
        if [ "$rc" = 2 ]; then
            mark_pending lint-unresolved "the lint budget of $MAX_LINTS runs ran out (LAND_CORE_BATCH_MAX_LINTS)"
            batch_finish
        fi
        lo=1; hi="$n"
        while [ "$lo" -lt "$hi" ]; do
            mid=$(((lo + hi) / 2))
            build_train "$mid"
            rc=0; lint_tree "the first $mid of $n" || rc=$?
            case "$rc" in
                0) lo=$((mid + 1)) ;;
                1) hi="$mid" ;;
                *) mark_pending lint-unresolved "the lint budget of $MAX_LINTS runs ran out (LAND_CORE_BATCH_MAX_LINTS)"; batch_finish ;;
            esac
        done
        culprit="${SURV[hi - 1]}"
        if [ "$hi" = 1 ]; then
            git reset --hard "$BASE_SHA" >/dev/null 2>&1 || batch_die "could not reset to the batch base $BASE_SHA — nothing pushed"
            rc=0; lint_tree "the batch base, no item merged" || rc=$?
            case "$rc" in
                1) mark_pending base-red "lint is red on $TARGET_BRANCH with no item merged — no item is blamed"; batch_finish ;;
                2) mark_pending lint-unresolved "the lint budget of $MAX_LINTS runs ran out (LAND_CORE_BATCH_MAX_LINTS)"; batch_finish ;;
            esac
        fi
        IFATE[culprit]=lint-dropped
        IN[culprit]="lint is red from this item on (bisected: the first $hi of $n fail)"
        echo "lint-dropped '${IB[culprit]}'; rebuilding the train without it." >&2
        drop_dependents
        build_train
    done

    collect_survivors
    [ "${#SURV[@]}" -gt 0 ] || batch_finish

    batch_set_items_env
    run_hook pre-push || { mark_pending pre-push-refused "the pre-push hook refused — nothing pushed"; batch_finish; }

    REMOTES=$(git remote 2>/dev/null) || REMOTES=""
    if [ -n "$REMOTES" ]; then
        echo "Pushing the train of ${#SURV[@]} (the integration worktree is detached — explicit refspec)..."
        if ! git push origin "HEAD:$TARGET_BRANCH"; then
            mark_pending push-failed "every merge is local-only in '$LAND_WORKTREE'; push it by hand with 'git -C \"$LAND_WORKTREE\" push origin HEAD:$TARGET_BRANCH' — do not reset"
            batch_table
            release_land_lock
            die "git push failed — the train is complete LOCALLY (in '$LAND_WORKTREE'); nothing was pushed, every branch is kept"
        fi
        PUSHED=1
        echo "pushed."
        echo
        echo "Note: '$MAIN_WORKTREE' was NOT fast-forwarded automatically (a sibling may hold uncommitted edits there). To update it:"
        echo "  git -C '$MAIN_WORKTREE' pull --ff-only"
    else
        echo "no remote configured — skipping push."
    fi

    for i in "${SURV[@]}"; do
        IFATE[i]=landed
        BRANCH="${IB[i]}"; LABEL="${IL[i]}"; MERGE_SHA="${IS[i]}"
        rc=0; run_hook post-push || rc=$?
        if [ "$rc" != 0 ]; then
            IFATE[i]=post-push-failed
            IN[i]="landed and pushed — not reverted — but the post-push hook failed (exit $rc); finish what it owns by hand"
        fi
        cleanup_branch "${IB[i]}" "${IW[i]}" "${IWF[i]}"
    done
    batch_finish
}

if [ "$LAND_EXISTS" = 1 ]; then
    if ! LAND_PLAN_STATUS=$(git -C "$LAND_WORKTREE" status --porcelain 2>&1); then
        LAND_STATE_DESC="exists, but its status could not be checked: $LAND_PLAN_STATUS"
    elif [ -z "$LAND_PLAN_STATUS" ]; then
        LAND_STATE_DESC="exists, clean"
    else
        LAND_STATE_DESC="exists, DIRTY:
$LAND_PLAN_STATUS"
    fi
else
    LAND_STATE_DESC="does not exist yet — will be created via 'git worktree add --detach' on '$TARGET_BRANCH'"
fi

# The lint preview reads the MAIN worktree; the gate reads the merged tree,
# which does not exist yet. They can disagree, hence "preview".
LINT_PREVIEW="(no lint command configured, and '$MAIN_WORKTREE/scripts/lint.sh' is not executable — will be skipped)"
if [ -n "$LINT_CMD" ]; then
    LINT_PREVIEW="$LINT_CMD"
elif [ -x "$MAIN_WORKTREE/scripts/lint.sh" ]; then
    LINT_PREVIEW="./scripts/lint.sh (preview from '$MAIN_WORKTREE'; the gate reads the merged tree)"
fi

if [ "$BATCH" = 1 ]; then
    batch_preflight
    batch_plan
else
    echo "Plan:"
    echo "  0. integration worktree: '$LAND_WORKTREE' ($LAND_STATE_DESC)"
    echo "  1. hook pre-merge${HOOK:+ ($HOOK)}"
    echo "  2. merge '$BRANCH' into '$TARGET_BRANCH' (--no-ff), inside the integration worktree"
    echo "  3. hook post-merge${HOOK:+ ($HOOK)}"
    echo "  4. lint on the merged tree: $LINT_PREVIEW"
    echo "  5. hook pre-push${HOOK:+ ($HOOK)}"
    echo "  6. git push origin HEAD:$TARGET_BRANCH (from the integration worktree; '$MAIN_WORKTREE' is not fast-forwarded automatically)"
    echo "  7. hook post-push${HOOK:+ ($HOOK)}"
    WT_PLAN=" git worktree remove${WT_RM_FORCE:+ $WT_RM_FORCE} $BRANCH_WT, then"
    [ -n "$BRANCH_WT" ] && [ "$BRANCH_WT" != "$MAIN_WORKTREE" ] || WT_PLAN=""
    echo "  8.$WT_PLAN git branch -d '$BRANCH'"
    [ -n "$HOOK" ] || echo "  (no --hook given — every hook step is a no-op)"
fi

if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "--dry-run: stopping before any git-mutating command, and before any hook call. Nothing was changed."
    exit 0
fi

echo
echo "Acquiring the integration worktree lock..."
acquire_land_lock "$LAND_WORKTREE.lock"

# Recomputed under the lock: the preflight read ran before this run held it,
# so another run could have created or removed the worktree in between.
if ! WT_PORCELAIN=$(git -C "$REPO_TOP" worktree list --porcelain 2>&1); then
    stop2 "could not re-evaluate 'git worktree list' after acquiring the lock: $WT_PORCELAIN"
fi
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

if [ "$LAND_EXISTS" != 1 ]; then
    if [ -e "$LAND_WORKTREE" ]; then
        stop2 "'$LAND_WORKTREE' exists on disk but is not a registered worktree of this repo — remove it or move it aside, then re-run"
    fi
    echo "Creating integration worktree '$LAND_WORKTREE' (detached, on '$TARGET_BRANCH')..."
    ADD_OUT=$(git -C "$MAIN_WORKTREE" worktree add --detach "$LAND_WORKTREE" "$TARGET_BRANCH" 2>&1) \
        || stop2 "could not create integration worktree '$LAND_WORKTREE': $ADD_OUT"
elif [ ! -e "$LAND_WORKTREE/.git" ]; then
    echo "Integration worktree '$LAND_WORKTREE' is registered but missing on disk — pruning and recreating..."
    git -C "$MAIN_WORKTREE" worktree prune >/dev/null 2>&1 || true
    ADD_OUT=$(git -C "$MAIN_WORKTREE" worktree add --detach "$LAND_WORKTREE" "$TARGET_BRANCH" 2>&1) \
        || stop2 "could not recreate integration worktree '$LAND_WORKTREE': $ADD_OUT"
fi

# Refuse a dirty integration worktree BEFORE the reset below, which would
# otherwise discard an uncommitted change silently. --reset-land opts in.
LAND_STATUS_PRE=$(git -C "$LAND_WORKTREE" status --porcelain 2>&1) \
    || stop2 "could not check integration worktree '$LAND_WORKTREE' status: $LAND_STATUS_PRE"
if [ -n "$LAND_STATUS_PRE" ]; then
    if [ "$RESET_LAND" = 1 ]; then
        echo "--reset-land: discarding uncommitted changes in '$LAND_WORKTREE':"
        printf '%s\n' "$LAND_STATUS_PRE"
        git -C "$LAND_WORKTREE" reset --hard >/dev/null 2>&1 || stop2 "--reset-land: 'git reset --hard' failed in '$LAND_WORKTREE'"
        git -C "$LAND_WORKTREE" clean -fd >/dev/null 2>&1 || stop2 "--reset-land: 'git clean -fd' failed in '$LAND_WORKTREE'"
    else
        stop2 "integration worktree '$LAND_WORKTREE' has uncommitted changes:
$LAND_STATUS_PRE
Pass --reset-land to discard them, or clean '$LAND_WORKTREE' by hand. '$MAIN_WORKTREE' is untouched either way."
    fi
fi

if git -C "$LAND_WORKTREE" remote 2>/dev/null | grep -qx origin; then
    echo "Fetching origin into '$LAND_WORKTREE'..."
    FETCH_OUT=$(git -C "$LAND_WORKTREE" fetch origin 2>&1) || stop2 "git fetch origin failed in '$LAND_WORKTREE': $FETCH_OUT"
    echo "Resetting '$LAND_WORKTREE' to origin/$TARGET_BRANCH..."
    git -C "$LAND_WORKTREE" reset --hard "origin/$TARGET_BRANCH" >/dev/null 2>&1 \
        || stop2 "could not reset '$LAND_WORKTREE' to origin/$TARGET_BRANCH — does that ref exist on origin?"
else
    warn "no 'origin' remote — syncing '$LAND_WORKTREE' to local '$TARGET_BRANCH' instead, and nothing will be pushed"
    git -C "$LAND_WORKTREE" reset --hard "$TARGET_BRANCH" >/dev/null 2>&1 \
        || stop2 "could not reset '$LAND_WORKTREE' to '$TARGET_BRANCH'"
fi
git -C "$LAND_WORKTREE" clean -fd >/dev/null 2>&1 \
    || stop2 "could not clean untracked files from '$LAND_WORKTREE' after reset"

cd "$LAND_WORKTREE"

[ "$BATCH" = 0 ] || batch_main

# Nothing is merged yet, so a refusal here needs no ORIG_HEAD revert — only
# the reset that undoes a commit the hook itself may have made.
HOOK_RC=0
run_hook pre-merge || HOOK_RC=$?
if [ "$HOOK_RC" != 0 ]; then
    reset_to_origin
    stop2 "the pre-merge hook refused (exit $HOOK_RC) — nothing merged, nothing pushed"
fi

echo
echo "Merging '$BRANCH' into '$TARGET_BRANCH'..."
MERGE_OUTPUT=""
if ! MERGE_OUTPUT=$(git merge --no-ff "$BRANCH" -m "$MERGE_MSG" 2>&1); then
    if ! CONFLICTS=$(git diff --name-only --diff-filter=U 2>&1); then
        CONFLICTS="(could not list conflicting files: $CONFLICTS)"
    fi
    git merge --abort >/dev/null 2>&1 || true
    if [ -n "$CONFLICTS" ]; then
        stop2 "merge conflict, aborted, nothing changed. Conflicting file(s):
$CONFLICTS"
    fi
    stop2 "git merge failed, aborted, nothing changed — not a content conflict (no conflicting files were left). git said:
$MERGE_OUTPUT"
fi

if ! STILL_UNMERGED=$(git diff --name-only --diff-filter=U 2>&1); then
    stop2_reset "could not verify the merge left no unmerged paths: $STILL_UNMERGED"
fi
[ -z "$STILL_UNMERGED" ] || stop2_reset "merge reported success but left unmerged paths — reverted:
$STILL_UNMERGED"
MERGE_SHA=$(git rev-parse HEAD)
echo "merged clean ($MERGE_SHA)."

run_hook post-merge || die_reset "the post-merge hook failed — merge reverted, nothing pushed"

EFFECTIVE_LINT="$LINT_CMD"
if [ -z "$EFFECTIVE_LINT" ] && [ -x ./scripts/lint.sh ]; then
    EFFECTIVE_LINT="./scripts/lint.sh"
fi
if [ -n "$EFFECTIVE_LINT" ]; then
    echo "Running $EFFECTIVE_LINT on the merged tree..."
    if ! bash -c "$EFFECTIVE_LINT"; then
        echo "lint failed on the merged tree — reverting the merge." >&2
        die_reset "lint failed; merge reverted, nothing pushed"
    fi
    echo "lint: clean."
else
    warn "no lint command configured (--lint-cmd / \$LAND_CORE_LINT_CMD) and no executable ./scripts/lint.sh in the merged tree — skipping"
fi

run_hook pre-push || die_reset "the pre-push hook failed — merge reverted, nothing pushed"

REMOTES=$(git remote 2>/dev/null) || REMOTES=""
if [ -n "$REMOTES" ]; then
    echo "Pushing (the integration worktree is detached — explicit refspec)..."
    if ! git push origin "HEAD:$TARGET_BRANCH"; then
        release_land_lock
        die "git push failed — the landing is complete LOCALLY (in '$LAND_WORKTREE'); resolve, then run 'git -C \"$LAND_WORKTREE\" push origin HEAD:$TARGET_BRANCH' by hand — do not reset, that would discard a completed landing"
    fi
    PUSHED=1
    echo "pushed."
    echo
    echo "Note: '$MAIN_WORKTREE' was NOT fast-forwarded automatically (a sibling may hold uncommitted edits there). To update it:"
    echo "  git -C '$MAIN_WORKTREE' pull --ff-only"
else
    echo "no remote configured — skipping push."
fi

# The push is the deploy. The landing stands whatever happens from here; a
# post-push failure is reported at the end and exits 1, never reverted.
HOOK_RC=0
run_hook post-push || HOOK_RC=$?
[ "$HOOK_RC" = 0 ] || POST_PUSH_FAILED="the post-push hook failed (exit $HOOK_RC)"

cleanup_branch "$BRANCH" "$BRANCH_WT" "$WT_RM_FORCE"

echo
if [ -n "$POST_PUSH_FAILED" ]; then
    release_land_lock
    die "branch '$BRANCH' landed on '$TARGET_BRANCH' and was pushed — the landing stands and was NOT reverted — but $POST_PUSH_FAILED. Whatever that hook owns is unfinished; finish it by hand"
fi
echo "branch '$BRANCH' landed on '$TARGET_BRANCH'."
release_land_lock
exit 0
