#!/bin/bash
#
# ghkit.sh — the GitHub reads more than one script in scripts/ has to agree
# about. Separate from kit.sh, which may not name a specific tool; `gh` is
# one, so it lives here instead.
#
# Usage: source this file, then call gh_required_contexts.
#
# The distinction this file exists to protect: a branch with NO required
# contexts and a branch whose rules CANNOT BE READ are different facts, and
# only one of them is a measurement. A private repo on GitHub Free answers
# 403 for the call a plan that could show rules would answer with an empty
# list, so a caller that reads the failure as "none" has not measured
# anything — and a caller that reads it as "refuse" blocks a repo that has
# nothing to wait for. Both mistakes have shipped here: pr-land.sh got it
# right, land-queue.sh refused every homelab landing (NWM-162).
#
# gh_required_contexts therefore returns THREE outcomes, not two, on the same
# reasoning that makes workspace-state reserve an exit code for "unreachable"
# rather than answering with an empty result:
#
#   0  read succeeded. VARNAME holds the contexts and MAY BE EMPTY, which
#      here means measured-and-none.
#   3  the rules are not visible (403/404). VARNAME is empty, and that empty
#      means cannot-be-measured. Never fold this into 0: a caller deciding
#      whether to WAIT wants the same answer for both, but a caller deciding
#      whether to BYPASS must never treat unreadable as proof of anything.
#   1  the read failed some other way. VARNAME holds the error text, for the
#      caller to print before it gives up.

# gh_unreadable_branch_rules TEXT — true when a branch-rules read failed
# because the rules are not visible, rather than because of a transport
# fault. gh puts the status in the message it prints.
gh_unreadable_branch_rules() {
    case "$1" in
        *'(HTTP 403)'*|*'(HTTP 404)'*) return 0 ;;
        *) return 1 ;;
    esac
}

# gh_required_contexts REPO BRANCH VARNAME — assign BRANCH's required
# status-check contexts, newline-separated and sorted, into VARNAME in the
# caller's shell. Returns 0 read, 3 not visible, 1 failed; see the header,
# because 0-with-nothing and 3 are different facts.
gh_required_contexts() {
    if [ $# -lt 3 ]; then
        echo "gh_required_contexts needs REPO BRANCH VARNAME" >&2
        return 2
    fi
    local _gh_repo="$1" _gh_branch="$2" _gh_var="$3" _gh_out _gh_rc
    _gh_out="$(gh api "repos/$_gh_repo/rules/branches/$_gh_branch" \
        --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' \
        2>&1)"
    _gh_rc=$?
    if [ "$_gh_rc" -eq 0 ]; then
        printf -v "$_gh_var" '%s' "$(printf '%s\n' "$_gh_out" | sed '/^[[:space:]]*$/d' | sort -u)"
        return 0
    fi
    if gh_unreadable_branch_rules "$_gh_out"; then
        printf -v "$_gh_var" '%s' ""
        return 3
    fi
    printf -v "$_gh_var" '%s' "$_gh_out"
    return 1
}
