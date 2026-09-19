#!/usr/bin/env bash
#
# git-retry.sh — run a git command, retrying only transient network failures.
#
# Wraps push/fetch/clone/pull for callers that run several git operations at
# once, where a dropped connection is common and a retry a second later
# usually succeeds. Everything else — a rejected ref, a merge conflict, a bad
# path — fails immediately, because retrying it would only repeat the error
# more slowly.
#
# Why it matches stderr rather than the exit code: git exits 128 for every
# fatal error, so the exit code cannot distinguish "the connection dropped"
# from "you are not allowed to push that". The patterns below are the
# transport-layer failures observed in practice; anything unmatched is treated
# as a real failure and is not retried.
#
# Backoff is deliberate. When several callers fail at once — the usual cause
# being a burst of simultaneous connections — retrying instantly from all of
# them recreates the burst. Each attempt waits longer, with a small per-caller
# jitter so they do not resynchronise.
#
# Usage:
#   git-retry.sh push -u origin my-branch
#   git-retry.sh fetch --prune origin
#   GIT_RETRY_ATTEMPTS=5 GIT_RETRY_BASE_DELAY=3 git-retry.sh push origin main
#
# Environment:
#   GIT_RETRY_ATTEMPTS     total attempts including the first (default 3)
#   GIT_RETRY_BASE_DELAY   seconds before the first retry, doubling (default 2)
#   GIT_RETRY_VERBOSE      set to 1 to print a line per retry decision
#
# Exit code is git's own, unchanged, from the final attempt. Stdout and stderr
# are passed through as git produced them.

set -uo pipefail

ATTEMPTS="${GIT_RETRY_ATTEMPTS:-3}"
BASE_DELAY="${GIT_RETRY_BASE_DELAY:-2}"
VERBOSE="${GIT_RETRY_VERBOSE:-0}"

case "${1:-}" in
    -h|--help)
        sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "")
        echo "git-retry.sh: no git command given (try --help)" >&2
        exit 2
        ;;
esac

case "$ATTEMPTS" in
    ''|*[!0-9]*) echo "git-retry.sh: GIT_RETRY_ATTEMPTS must be a number, got: $ATTEMPTS" >&2; exit 2 ;;
esac
[ "$ATTEMPTS" -ge 1 ] || { echo "git-retry.sh: GIT_RETRY_ATTEMPTS must be at least 1" >&2; exit 2; }

# is_transient TEXT — true when git's stderr names a transport failure that a
# later attempt could plausibly get past.
is_transient() {
    printf '%s' "$1" | grep -qiE \
        'Operation timed out|Connection closed by|Connection reset by peer|Connection refused|Could not read from remote repository|The remote end hung up unexpectedly|RPC failed|early EOF|index-pack failed|Failed to connect to|Could not resolve host|ssh_exchange_identification|kex_exchange_identification|Broken pipe|TLS connection was non-properly terminated|HTTP/2 stream .* was not closed cleanly|unexpected disconnect while reading sideband'
}

say() { [ "$VERBOSE" = "1" ] && echo "git-retry.sh: $*" >&2; return 0; }

attempt=1
delay="$BASE_DELAY"
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

while :; do
    git "$@" 2> >(tee "$err_file" >&2)
    rc=$?
    [ "$rc" -eq 0 ] && exit 0

    stderr_text="$(cat "$err_file" 2>/dev/null || true)"

    if [ "$attempt" -ge "$ATTEMPTS" ]; then
        say "attempt $attempt/$ATTEMPTS failed (exit $rc); no attempts left"
        exit "$rc"
    fi

    if ! is_transient "$stderr_text"; then
        say "attempt $attempt/$ATTEMPTS failed (exit $rc); not a transport error, not retrying"
        exit "$rc"
    fi

    jitter=$(( ($$ % 5) ))
    say "attempt $attempt/$ATTEMPTS hit a transport error; retrying in $((delay + jitter))s"
    sleep "$((delay + jitter))"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
done
