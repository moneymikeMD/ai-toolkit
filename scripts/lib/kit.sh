#!/bin/bash
#
# kit.sh — the shared shell helpers scripts/ sources. Generic only: nothing
# here may name a host, a vault, a multiplexer or any other specific tool.
# A helper that does belongs in the consuming repo, not in this one.
#
# Usage: source this file, then call die/warn/need/show_help/known_command/tmpfile.
#
# tmpfile takes a VARIABLE NAME and assigns into the caller's shell:
#
#     tmpfile ENGINE || die "could not create the engine tempfile"
#
# Deliberately not `f=$(tmpfile)`. A command substitution runs in a subshell,
# so the cleanup trap registered there fired and deleted the file before the
# caller saw the path; the caller then recreated it at the default umask,
# losing the 0600 and leaking it. Both guarantees this file documents were
# silently absent until that was fixed. homelab hit the same defect in
# labkit.sh (LAB-103) and measured 3,523 leaked files, some holding real
# 1Password values, so treat a regression here as a security bug, not a nit.
#
# Two rules for anything calling tmpfile:
#   - Do not set your own `trap ... EXIT`. bash keeps one handler per signal,
#     so yours REPLACES the cleanup below and it silently stops running
#     (homelab filed the same trap as LAB-104). Call the other cleanup from
#     your handler, or do not trap EXIT.
#   - Calling tmpfile more than once is safe; each call appends to the
#     cleanup list rather than re-registering the trap.

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

# tmpfile VARNAME — create a 0600 tempfile, assign its path to VARNAME in the
# caller's shell, remove it on exit. Not `f=$(tmpfile)`; see the header.
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
