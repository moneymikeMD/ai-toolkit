#!/bin/bash
#
# Run each plugin's `claude plugin eval` suite under one cost ceiling and
# compare every case's mean score with that plugin's recorded baseline.
# Built to run unattended (a timer); it prints what it did and exits non-zero
# naming every case that fell.
#
# Usage:
#   eval-weekly.sh [--max-cost-usd N] [--state-dir DIR] [--dry-run] PLUGIN_DIR...
#
# For each PLUGIN_DIR (a plugin checkout) it runs:
#   claude plugin eval PLUGIN_DIR --runs 3 --no-publish --json
#     --max-cost-usd <remaining> --output-dir <state>/<date>/<plugin>
#     --ablation none --threshold 0 --trust-plugin
# then reads <output-dir>/aggregate-result.json and compares each case's
# .aggregates.score with PLUGIN_DIR/evals/results/baseline.tsv (columns
# case, mean_score, ...; header row first).
#
# A case FELL when its score is more than 0.1 below its baseline, or when a
# baseline case has no score in the run (not run, or cut off by the ceiling).
# A baseline row matching no case name is a group: it is compared with the
# mean of the run's cases named `<row>-*` that have no baseline row of their
# own, reported once with the member count, and falls if no member ran.
# A case with no baseline row and no group is reported and never fails the run.
# An eval exit of 2 (its --max-cost-usd ceiling reached) fails the run.
#
# Options:
#   --max-cost-usd N  total ceiling across all plugins, USD (default 10). Each
#                     plugin gets what the earlier ones left; a plugin reached
#                     with nothing left is not run and its baseline cases fall.
#                     10 is the figure the ticket started from (NWM-258); the
#                     owner has not confirmed it.
#   --state-dir DIR   where results go (default ~/.local/state/skill-evals)
#   --dry-run         print the eval command per plugin; run nothing
#
# Why the extra flags: --ablation none because baselines are taken with it
# (the no-plugin arm doubles the cost); --threshold 0 so the eval's own exit
# code means "the run failed", not "a case scored under 1.0"; --trust-plugin
# because nobody is there to answer the first-run trust prompt.
#
# Billing: each eval run is a full `claude` child on the caller's own
# credential (`claude plugin eval --help`, Claude Code 2.1.332). On desktop on
# 2026-11-25 `claude auth status` reported authMethod claude.ai (Max) and no
# ANTHROPIC_API_KEY was set, so a run there draws on the subscription and
# costUsd is the harness's notional figure. An exported ANTHROPIC_API_KEY
# would bill the API instead (UNVERIFIED); the script prints which one applies.
#
# Exit: 0 nothing fell; 1 a case fell or a plugin's run failed; 64 usage.
#
# EVAL_WEEKLY_CLAUDE overrides the claude binary (the selftest's stub).

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

CLAUDE="${EVAL_WEEKLY_CLAUDE:-claude}"
MAX_COST=10
STATE_DIR="${HOME}/.local/state/skill-evals"
DRY_RUN=0
PLUGINS=()

usage_die() { echo "Error: $*" >&2; exit 64; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        --max-cost-usd) [ $# -ge 2 ] || usage_die "--max-cost-usd needs a value"; MAX_COST="$2"; shift 2 ;;
        --state-dir) [ $# -ge 2 ] || usage_die "--state-dir needs a value"; STATE_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --) shift; PLUGINS+=("$@"); break ;;
        -*) usage_die "unknown option '$1' (see --help)" ;;
        *) PLUGINS+=("$1"); shift ;;
    esac
done

[ ${#PLUGINS[@]} -gt 0 ] || usage_die "name at least one plugin checkout"
[ -n "$STATE_DIR" ] || usage_die "--state-dir is empty"
printf '%s' "$MAX_COST" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || usage_die "--max-cost-usd must be a non-negative number, got '$MAX_COST'"

need python3

plugin_name() {
    local dir="$1" name=""
    if [ -f "$dir/.claude-plugin/plugin.json" ]; then
        name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$dir/.claude-plugin/plugin.json" 2>/dev/null || true)
    fi
    [ -n "$name" ] || name=$(basename "$dir")
    printf '%s\n' "$name"
}

# compare BASELINE RESULT_OR_EMPTY — prints one line per case, last line "fell=N".
compare() {
    python3 - "$1" "$2" <<'PY'
import json, sys
baseline_path, result_path = sys.argv[1], sys.argv[2]
base = {}
with open(baseline_path) as f:
    for i, line in enumerate(f):
        cols = line.rstrip("\n").split("\t")
        if i == 0 or len(cols) < 2 or not cols[0]:
            continue
        try:
            base[cols[0]] = float(cols[1])
        except ValueError:
            print(f"  bad baseline row: {line.rstrip()}")
scores = {}
if result_path:
    with open(result_path) as f:
        for c in json.load(f).get("cases", []):
            s = (c.get("aggregates") or {}).get("score")
            if s is not None:
                scores[c["name"]] = float(s)
scores_all = dict(scores)
groups = {g: [] for g in base if g not in scores}
for name in [n for n in scores if n not in base]:
    owners = [g for g in groups if name.startswith(g + "-")]
    if owners:
        groups[max(owners, key=len)].append(name)
        del scores[name]
for g, members in groups.items():
    if members:
        scores[g] = sum(scores_all[m] for m in members) / len(members)
fell = 0
for name in sorted(set(base) | set(scores)):
    b, s = base.get(name), scores.get(name)
    n = len(groups.get(name) or [])
    tag = f"\t(mean of {n} cases)" if n else ""
    if b is None:
        print(f"  NEW   {name}\tscore={s:.3f}\t(no baseline row)")
    elif s is None:
        fell += 1
        print(f"  FELL  {name}\tbaseline={b:.3f}\t(no score this run)")
    elif s < b - 0.1 - 1e-9:
        fell += 1
        print(f"  FELL  {name}\tscore={s:.3f}\tbaseline={b:.3f}{tag}")
    else:
        print(f"  ok    {name}\tscore={s:.3f}\tbaseline={b:.3f}{tag}")
print(f"fell={fell}")
PY
}

result_cost() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("costUsd") or 0)' "$1" 2>/dev/null || echo 0
}

fadd() { python3 -c 'import sys; print(f"{float(sys.argv[1]) + float(sys.argv[2]):.4f}")' "$1" "$2"; }
fpos() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$1"; }

DATE=$(date +%F)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "credential: ANTHROPIC_API_KEY is set; eval runs may bill the API"
else
    echo "credential: no ANTHROPIC_API_KEY; eval runs use the logged-in claude credential"
fi

FAILED=()
SPENT=0
for dir in "${PLUGINS[@]}"; do
    [ -d "$dir" ] || { warn "not a directory: $dir"; FAILED+=("$dir: not a directory"); continue; }
    dir=$(cd "$dir" && pwd)
    name=$(plugin_name "$dir")
    baseline="$dir/evals/results/baseline.tsv"
    out="$STATE_DIR/$DATE/$name"
    remaining=$(fadd "$MAX_COST" "-$SPENT")
    cmd=("$CLAUDE" plugin eval "$dir" --runs 3 --no-publish --json
         --max-cost-usd "$remaining" --output-dir "$out"
         --ablation none --threshold 0 --trust-plugin)

    if [ "$DRY_RUN" = 1 ]; then
        printf '%q ' "${cmd[@]}"; echo
        continue
    fi

    echo "== $name ($dir)"
    if [ ! -f "$baseline" ]; then
        warn "  no baseline at $baseline; not run"
        FAILED+=("$name: no baseline.tsv")
        continue
    fi
    if ! fpos "$remaining"; then
        echo "  not run: the \$$MAX_COST ceiling is spent"
        report=$(compare "$baseline" "")
    else
        mkdir -p "$out"
        rm -f "$out/aggregate-result.json" "$out/result.json"
        rc=0
        "${cmd[@]}" >"$out/result.json" 2>"$out/stderr.txt" || rc=$?
        agg="$out/aggregate-result.json"
        [ -f "$agg" ] || agg="$out/result.json"
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$agg" 2>/dev/null; then
            warn "  eval exited $rc with no readable result; see $out/stderr.txt"
            FAILED+=("$name: eval exited $rc, no result")
            continue
        fi
        cost=$(result_cost "$agg")
        SPENT=$(fadd "$SPENT" "$cost")
        echo "  eval exit=$rc cost=\$$cost (total \$$SPENT of \$$MAX_COST) results=$out"
        case "$rc" in
            0) ;;
            2) echo "  the eval's \$$remaining ceiling was reached (exit 2); cases may be cut off"
               FAILED+=("$name: eval exited 2, its \$$remaining --max-cost-usd ceiling was reached") ;;
            *) FAILED+=("$name: eval exited $rc") ;;
        esac
        report=$(compare "$baseline" "$agg")
    fi
    printf '%s\n' "$report" | sed '$d'
    while IFS= read -r line; do
        case "$line" in
            "  FELL  "*) c=${line#  FELL  }; FAILED+=("$name: ${c%%	*} fell") ;;
        esac
    done <<<"$report"
done

[ "$DRY_RUN" = 1 ] && exit 0
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "FAILED:"
    printf '  %s\n' "${FAILED[@]}"
    exit 1
fi
echo "nothing fell"
