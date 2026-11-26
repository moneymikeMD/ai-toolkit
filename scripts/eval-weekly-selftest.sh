#!/bin/bash
#
# Selftest for eval-weekly.sh. Never runs a real eval: EVAL_WEEKLY_CLAUDE
# points at a stub that copies a fixture result into --output-dir, and PATH
# leads with a tripwire `claude` that records any call and fails.
#
# Usage: scripts/eval-weekly-selftest.sh [path-to-eval-weekly.sh]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-$HERE/eval-weekly.sh}"
[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >>"$WORK/tripwire"
exit 99
EOF
cat >"$WORK/stub-claude" <<EOF
#!/bin/bash
echo "\$*" >>"$WORK/calls"
dir="\$3" out=""
while [ \$# -gt 0 ]; do
    [ "\$1" = --output-dir ] && out="\$2"
    shift
done
mkdir -p "\$out"
if [ -f "\$dir/stub-result.json" ]; then
    cp "\$dir/stub-result.json" "\$out/aggregate-result.json"
    cat "\$dir/stub-result.json"
fi
exit "\$(cat "\$dir/stub-rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$WORK/bin/claude" "$WORK/stub-claude"
unset ANTHROPIC_API_KEY
export PATH="$WORK/bin:$PATH" EVAL_WEEKLY_CLAUDE="$WORK/stub-claude"

# plugin NAME COST "case=score ..." "case=baseline ..." — build a fixture checkout.
plugin() {
    local d="$WORK/p/$1" kv
    rm -rf "$d"
    mkdir -p "$d/.claude-plugin" "$d/evals/results"
    printf '{"name":"%s"}\n' "$1" >"$d/.claude-plugin/plugin.json"
    python3 - "$d/stub-result.json" "$2" "$3" <<'PY'
import json, sys
cases = [{"name": k, "aggregates": {"score": float(v)}} for k, v in (p.split("=") for p in sys.argv[3].split())]
json.dump({"costUsd": float(sys.argv[2]), "partial": False, "cases": cases}, open(sys.argv[1], "w"))
PY
    printf 'case\tmean_score\tagent_launched\tclaude_code_version\tdate\n' >"$d/evals/results/baseline.tsv"
    for kv in $4; do
        printf '%s\t%s\tyes\t2.1.332\t2026-11-25\n' "${kv%%=*}" "${kv#*=}" >>"$d/evals/results/baseline.tsv"
    done
    printf '%s\n' "$d"
}

run() {
    : >"$WORK/calls"
    RC=0
    OUT=$("$SCRIPT" --state-dir "$WORK/state" "$@" 2>&1) || RC=$?
}
has()   { printf '%s' "$OUT" | grep -qF -- "$1"; }

A=$(plugin alpha 1.5 "c1=1.0 c2=0.9" "c1=1.000 c2=1.000")
run "$A"
[ "$RC" = 0 ] && has "nothing fell" && ok "0.1 below baseline is not a fall" || bad "boundary: rc=$RC $OUT"
[ -f "$WORK/state/$(date +%F)/alpha/aggregate-result.json" ] && ok "results land in <state>/<date>/<plugin>" || bad "output dir"
has "no ANTHROPIC_API_KEY" && ok "names the credential in use" || bad "credential line"
grep -q -- "--runs 3 --no-publish --json --max-cost-usd 10.0000 --output-dir" "$WORK/calls" \
    && ok "eval runs with the ticket's flags and the default \$10 ceiling" || bad "flags: $(cat "$WORK/calls")"

A=$(plugin alpha 1 "c1=1.0 c2=0.85 c3=0.5" "c1=1.000 c2=0.963")
run "$A"
[ "$RC" = 1 ] && has "alpha: c2 fell" && ! has "alpha: c1 fell" && ok "a case more than 0.1 below falls and is named" || bad "fall: rc=$RC $OUT"
has "NEW   c3" && ! has "alpha: c3 fell" && ok "a case with no baseline row is reported, not failed" || bad "new case: $OUT"

A=$(plugin alpha 1 "c1=1.0" "c1=1.000 gone=1.000")
run "$A"
[ "$RC" = 1 ] && has "alpha: gone fell" && ok "a baseline case missing from the run falls" || bad "missing: rc=$RC $OUT"

A=$(plugin alpha 2.5 "c1=1.0" "c1=1.0")
B=$(plugin beta 0.1 "b1=1.0" "b1=1.0")
run --max-cost-usd 3 "$A" "$B"
[ "$RC" = 0 ] && grep "$WORK/p/beta" "$WORK/calls" | grep -q -- "--max-cost-usd 0.5000" \
    && ok "the ceiling is a total: the next plugin gets what is left" || bad "ceiling split: $(cat "$WORK/calls") $OUT"

A=$(plugin alpha 3 "c1=1.0" "c1=1.0")
run --max-cost-usd 3 "$A" "$B"
[ "$RC" = 1 ] && has "beta: b1 fell" && ! grep -q "$WORK/p/beta" "$WORK/calls" \
    && ok "a plugin reached with the ceiling spent is not run and its cases fall" || bad "spent: rc=$RC $OUT"

A=$(plugin alpha 1 "c1=1.0" "c1=1.0")
printf '2\n' >"$A/stub-rc"
run "$A"
[ "$RC" = 1 ] && has "ceiling was reached" && has "alpha: eval exited 2" \
    && ok "eval exit 2 (its ceiling reached) fails the run and says so" || bad "rc2: rc=$RC $OUT"

A=$(plugin alpha 1 "trigger-x-fire-1=1.0 trigger-x-miss-1=0.667" "trigger-x=0.9")
run "$A"
[ "$RC" = 0 ] && has "ok    trigger-x	score=0.834	baseline=0.900	(mean of 2 cases)" && ! has "NEW   trigger-x-" \
    && ok "a group baseline row is compared with the mean of its cases, which are not NEW" || bad "group: rc=$RC $OUT"

A=$(plugin alpha 1 "trigger-x-fire-1=1.0 trigger-x-miss-1=0.5" "trigger-x=0.9")
run "$A"
[ "$RC" = 1 ] && has "alpha: trigger-x fell" && ok "a group whose mean is more than 0.1 below falls" || bad "group fall: rc=$RC $OUT"

A=$(plugin alpha 1 "c1=1.0" "c1=1.0 trigger-x=0.9")
run "$A"
[ "$RC" = 1 ] && has "alpha: trigger-x fell" && ok "a group row with no member in the run falls" || bad "group missing: rc=$RC $OUT"

A=$(plugin alpha 1 "trigger-x-fire-1=1.0 trigger-x-fire-2=0.0" "trigger-x=0.9 trigger-x-fire-2=0.0")
run "$A"
has "ok    trigger-x	score=1.000	baseline=0.900	(mean of 1 cases)" && has "ok    trigger-x-fire-2" \
    && ok "a case with its own baseline row is not counted in a group" || bad "group exclusion: rc=$RC $OUT"

A=$(plugin alpha 1 "c1=1.0" "c1=1.0")
rm "$A/stub-result.json"; printf '1\n' >"$A/stub-rc"
run "$A"
[ "$RC" = 1 ] && has "alpha: eval exited 1, no result" && ok "a failed eval with no result fails the run" || bad "no result: rc=$RC $OUT"

A=$(plugin alpha 1 "c1=1.0" "c1=1.0")
rm "$A/evals/results/baseline.tsv"
run "$A"
[ "$RC" = 1 ] && has "no baseline.tsv" && [ ! -s "$WORK/calls" ] && ok "no baseline: not run, fails" || bad "no baseline: rc=$RC $OUT"

A=$(plugin alpha 1 "c1=1.0" "c1=1.0")
run --dry-run "$A" "$B"
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c 'plugin eval')" = 2 ] && [ ! -s "$WORK/calls" ] \
    && ok "--dry-run prints one command per plugin and runs none" || bad "dry-run: rc=$RC $OUT"

run --max-cost-usd abc "$A"
[ "$RC" = 64 ] && ok "a non-numeric ceiling is a usage error" || bad "bad ceiling rc=$RC"
run
[ "$RC" = 64 ] && ok "no plugin named is a usage error" || bad "no args rc=$RC"
ANTHROPIC_API_KEY=x run --dry-run "$A"
has "ANTHROPIC_API_KEY is set" && ok "an exported API key is called out" || bad "api key line: $OUT"

[ ! -e "$WORK/tripwire" ] && ok "the real claude was never invoked" || bad "tripwire hit: $(cat "$WORK/tripwire")"

echo "eval-weekly selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
