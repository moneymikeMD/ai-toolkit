#!/bin/bash
#
# Selftest for scripts/lib/kit.sh.
#
# Weighted at tmpfile, which shipped delivering neither guarantee it documented
# and failed silently rather than loudly. Guards three regressions:
#   1. `f=$(tmpfile)` ran the cleanup trap in the command-substitution subshell,
#      so the path was dead on return and the caller recreated it at the default
#      umask (0644, not 0600) and leaked it.
#   2. Registering the trap per call would leave only the last path cleaned up.
#   3. show_help must read the CALLER's header, not this library's.
#
# The path-still-exists assertion is what keeps the cleanup assertion honest:
# without it, an implementation that deleted eagerly would pass for free. That
# is not hypothetical — the first draft of this file passed against the broken
# tmpfile for exactly that reason.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$HERE/lib/kit.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "NOT OK - $1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; echo "    want: $3"; echo "    got:  $2"; }; }

[ -f "$KIT" ] || { echo "kit.sh not found at $KIT" >&2; exit 1; }

# shellcheck source=lib/kit.sh
. "$KIT"

# --- die / warn -----------------------------------------------------------
out=$(bash -c '. "$1"; die "boom"' _ "$KIT" 2>&1); rc=$?
check "die prints to stderr and exits 1" "$rc|$out" "1|Error: boom"

out=$(bash -c '. "$1"; warn "heads up"; echo after' _ "$KIT" 2>&1); rc=$?
check "warn does not exit" "$rc|$out" "0|heads up
after"

# --- need -----------------------------------------------------------------
bash -c '. "$1"; need sh' _ "$KIT" >/dev/null 2>&1 \
    && ok "need accepts a command on PATH" || bad "need accepts a command on PATH"

out=$(bash -c '. "$1"; need definitely-not-a-real-command-xyz' _ "$KIT" 2>&1); rc=$?
case "$rc|$out" in
    "1|Error: required command not found on PATH: definitely-not-a-real-command-xyz")
        ok "need dies naming the missing command" ;;
    *)  bad "need dies naming the missing command"; echo "    got: $rc|$out" ;;
esac

# --- known_command --------------------------------------------------------
known_command add add resolve lint && ok "known_command finds a match" \
    || bad "known_command finds a match"
known_command nope add resolve lint && bad "known_command rejects a non-match" \
    || ok "known_command rejects a non-match"

# --- show_help reads the caller's header, not the library's ---------------
CALLER=$(mktemp "${TMPDIR:-/tmp}/kit-selftest-caller.XXXXXX")
cat > "$CALLER" <<CALLEREOF
#!/bin/bash
# caller-header-line-one
# caller-header-line-two

. "$KIT"
show_help
CALLEREOF
chmod +x "$CALLER"
out=$("$CALLER" 2>&1); rc=$?
rm -f "$CALLER"
check "show_help prints the caller's header and exits 0" "$rc|$out" "0|caller-header-line-one
caller-header-line-two"

# --- tmpfile --------------------------------------------------------------
# See this file's header for what these three guard and why they are paired.

out=$(bash -c '. "$1"; tmpfile f; [ -e "$f" ] && echo "EXISTS $f"' _ "$KIT")
case "$out" in
    "EXISTS "/*) ok "tmpfile's path exists when it returns (not eaten by a subshell)" ;;
    *) bad "tmpfile's path exists when it returns (not eaten by a subshell)"; echo "    got: $out" ;;
esac

mode=$(bash -c '. "$1"; tmpfile f; stat -c "%a" "$f" 2>/dev/null || stat -f "%OLp" "$f"' _ "$KIT")
check "tmpfile creates the file 0600" "$mode" "600"

# Write through the handle the way a caller does, then confirm 0600 survives.
mode=$(bash -c '. "$1"; tmpfile f; cat > "$f" <<<body; stat -c "%a" "$f" 2>/dev/null || stat -f "%OLp" "$f"' _ "$KIT")
check "tmpfile stays 0600 after the caller writes to it" "$mode" "600"

paths=$(bash -c '
    . "$1"
    tmpfile a; tmpfile b; tmpfile c
    printf "%s\n%s\n%s\n" "$a" "$b" "$c"
' _ "$KIT")
distinct=$(echo "$paths" | sort -u | grep -c '^/')
check "tmpfile returns three distinct paths" "$distinct" "3"

alive=0
while IFS= read -r p; do [ -e "$p" ] && alive=$((alive + 1)); done <<< "$paths"
check "tmpfile removes every path on exit, not just the last" "$alive" "0"

out=$(bash -c '. "$1"; tmpfile' _ "$KIT" 2>&1); rc=$?
check "tmpfile with no variable name dies" "$rc|$out" "1|Error: tmpfile needs a variable name to assign into"

echo
echo "$PASS passed, $FAIL failed (against: $KIT)"
[ "$FAIL" -eq 0 ]
