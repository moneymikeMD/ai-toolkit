#!/bin/bash
#
# kit.sh — the shared shell helpers scripts/ sources. Generic only: nothing
# here may name a host, a vault, a multiplexer or any other specific tool.
# A helper that does belongs in the consuming repo, not in this one.
#
# Usage: source this file, then call die/warn/need/show_help/known_command/tmpfile.

# die MESSAGE... — print to stderr, exit 1.
die() { echo "Error: $*" >&2; exit 1; }

# warn MESSAGE... — print to stderr, keep going.
warn() { echo "$*" >&2; }

# need CMD... — die if any named command is not on PATH.
need() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command not found on PATH: $cmd"
    done
}

# show_help — print the calling script's leading '#'-comment header (shebang to
# the first non-comment, non-blank line) with '# ' stripped, then exit 0.
show_help() {
    awk '
        NR == 1 && /^#!/ { next }
        /^#/ { sub(/^# ?/, ""); print; next }
        /^[[:space:]]*$/ { next }
        { exit }
    ' "$0"
    exit 0
}

# known_command WANT CANDIDATE... — 0 if WANT is one of the candidates.
known_command() {
    local want="$1" c
    shift
    for c in "$@"; do [ "$c" = "$want" ] && return 0; done
    return 1
}

# tmpfile VARNAME — create a 0600 tempfile and assign its path to VARNAME in
# the CALLER's shell, removing it on exit. Deliberately not `f=$(tmpfile)`:
# a command substitution runs in a subshell, so the cleanup trap would fire
# there and delete the file before the caller ever saw the path, leaving the
# caller to recreate it at the default umask and leak it.
# Safe to call more than once: each call adds its own path to the cleanup
# list rather than replacing an earlier trap registration.
#
# A script that installs its own `trap ... EXIT` REPLACES the one set here,
# because bash keeps one handler per signal — cleanup then silently stops and
# 0600 tempfiles accumulate. Call the other cleanup from your own handler, or
# do not trap EXIT in a script that uses tmpfile.
_KIT_TMPFILES=""
_kit_cleanup() {
    [ -n "$_KIT_TMPFILES" ] || return 0
    # shellcheck disable=SC2086  # deliberate word splitting: a newline-joined path list
    rm -f $_KIT_TMPFILES 2>/dev/null || true
}
tmpfile() {
    [ $# -ge 1 ] || die "tmpfile needs a variable name to assign into"
    local _kit_var="$1" _kit_f
    _kit_f=$(mktemp "${TMPDIR:-/tmp}/kit.XXXXXX") || return 1
    chmod 600 "$_kit_f" || { rm -f "$_kit_f"; return 1; }
    if [ -z "$_KIT_TMPFILES" ]; then
        trap _kit_cleanup EXIT
    fi
    _KIT_TMPFILES="$_KIT_TMPFILES
$_kit_f"
    printf -v "$_kit_var" '%s' "$_kit_f"
}
