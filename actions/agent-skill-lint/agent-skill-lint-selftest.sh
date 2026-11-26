#!/bin/bash
#
# Selftest for agent-skill-lint. Builds a scratch fixture tree of agents and
# skills, runs the script standalone against each case, then runs the composite
# action's own step body so the input plumbing and report-only guard are proven.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/agent-skill-lint.py"

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

words() { python3 -c 'import sys; print(" ".join(["word"] * int(sys.argv[1])))' "$1"; }

write_skill() {
  mkdir -p "$work/$1/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\nbody\n' "$3" "$4" > "$work/$1/$2/SKILL.md"
}

write_agent() {
  mkdir -p "$work/$1"
  printf -- '---\nname: %s\ndescription: an agent\n%b---\n%s\n' "$2" "$3" "$4" > "$work/$1/$2.md"
}

lint() {
  set +e
  OUT=$(python3 "$LINT" "$@" 2>&1)
  RC=$?
  set -e
}

expect() {
  local desc="$1" rc="$2" pattern="$3"
  if [ "$RC" -eq "$rc" ] && { [ -z "$pattern" ] || printf '%s\n' "$OUT" | grep -qE -- "$pattern"; }; then
    ok "$desc"
  else
    bad "$desc (rc=$RC, output: $OUT)"
  fi
}

# ---- clean tree ----------------------------------------------------------
write_skill clean/skills shell-scripting shell-scripting 'Conventions for scripts.'
write_agent clean/agents author 'skills:\n  - shell-scripting\n  - night-watchman:tickets-protocol\n' \
  'Load the `shell-scripting` skill, then invoke the night-watchman:tickets-protocol skill.'
lint --agent-root "$work/clean/agents" --skill-root "$work/clean/skills"
expect "a clean tree exits 0" 0 '^agent-skill-lint: clean$'

# ---- (1) word cap and allow ---------------------------------------------
write_agent cap/agents fat '' "$(words 201)"
write_agent cap/agents thin '' "$(words 200)"
lint --agent-root "$work/cap/agents"
expect "a 201-word body breaks the default 200 cap" 1 'fat\.md: agent-word-cap: body is 201 words, cap 200'
if printf '%s\n' "$OUT" | grep -q 'thin\.md'; then bad "a 200-word body is within the cap"; else ok "a 200-word body is within the cap"; fi
lint --agent-root "$work/cap/agents" --agent-word-cap 250
expect "--agent-word-cap raises the cap" 0 ''
printf '{"%s": "kept whole: research needs its method inline"}\n' "$work/cap/agents/fat.md" > "$work/allow.json"
lint --agent-root "$work/cap/agents" --allow "$work/allow.json"
expect "an allow entry with a reason exempts the agent" 0 ''
printf '{"%s": "  "}\n' "$work/cap/agents/fat.md" > "$work/allow-empty.json"
lint --agent-root "$work/cap/agents" --allow "$work/allow-empty.json"
expect "an allow entry with an empty reason does not exempt" 1 'agent-word-cap'
printf 'not json' > "$work/allow-bad.json"
lint --agent-root "$work/cap/agents" --allow "$work/allow-bad.json"
expect "an unreadable allow file is a usage error" 2 'cannot read --allow'

# ---- (2) unbacked skill load ---------------------------------------------
write_skill unbacked/skills grill grill 'Interview the owner.'
write_agent unbacked/agents prose '' 'Before starting, read the `grill` skill and load the to-issues skill.'
write_agent unbacked/agents generic '' 'Load the relevant skill for the task.'
lint --agent-root "$work/unbacked/agents" --skill-root "$work/unbacked/skills"
expect "a backticked skill load with no skills: entry is flagged" 1 "prose\.md: unbacked-skill-load: body loads skill 'grill'"
expect "a hyphenated bare skill load with no skills: entry is flagged" 1 "prose\.md: unbacked-skill-load: body loads skill 'to-issues'"
if printf '%s\n' "$OUT" | grep -q 'generic\.md'; then bad "an unnamed 'relevant skill' is not a load"; else ok "an unnamed 'relevant skill' is not a load"; fi

# ---- (3) SKILL.md validity ---------------------------------------------
write_skill bad/skills wrong-dir other-name 'Fine description.'
write_skill bad/skills angle angle 'Use for <thing> work.'
write_skill bad/skills long long "$(python3 -c 'print("x" * 1025)')"
write_skill bad/skills edge edge "$(python3 -c 'print("x" * 1024)')"
mkdir -p "$work/bad/skills/nodesc"
printf -- '---\nname: nodesc\n---\nbody\n' > "$work/bad/skills/nodesc/SKILL.md"
mkdir -p "$work/bad/skills/huge"
{ printf -- '---\nname: huge\ndescription: Big.\n---\n'; for _ in $(seq 497); do echo line; done; } > "$work/bad/skills/huge/SKILL.md"
mkdir -p "$work/bad/skills/folded"
printf -- '---\nname: folded\ndescription: >\n  A folded\n  description.\n---\nbody\n' > "$work/bad/skills/folded/SKILL.md"
lint --skill-root "$work/bad/skills"
expect "name must equal the directory" 1 "wrong-dir/SKILL\.md: skill-name: name 'other-name' does not match directory 'wrong-dir'"
expect "a description with < or > is flagged" 1 'angle/SKILL\.md: skill-description: contains < or >'
expect "a 1025-character description is flagged" 1 'long/SKILL\.md: skill-description: 1025 characters, limit 1024'
expect "a missing description is flagged" 1 'nodesc/SKILL\.md: skill-frontmatter: missing description'
expect "a 501-line SKILL.md is flagged" 1 'huge/SKILL\.md: skill-length: 501 lines, limit 500'
for s in edge folded; do
  if printf '%s\n' "$OUT" | grep -q "/$s/SKILL.md"; then bad "$s SKILL.md is valid"; else ok "$s SKILL.md is valid"; fi
done

# ---- (4) skills: names an existing skill ----------------------------------
write_skill unknown/skills real real 'Exists.'
write_agent unknown/agents thin 'skills: [real, missing, other-plugin:elsewhere]\n' 'Do the work.'
lint --agent-root "$work/unknown/agents" --skill-root "$work/unknown/skills"
expect "an un-namespaced skills: name not under any root is flagged" 1 "thin\.md: unknown-skill: \`skills:\` names 'missing'"
if printf '%s\n' "$OUT" | grep -qE "'(real|other-plugin:elsewhere)'"; then
  bad "an existing or namespaced skills: name is not flagged"
else
  ok "an existing or namespaced skills: name is not flagged"
fi

lint --agent-root "$work/nope"
expect "a missing root is a usage error" 2 'not a directory'

# ---- the composite action's own step body --------------------------------
extract_step_body() {
  awk '
    /^[[:space:]]*run: \|/ { capture = 1; indent = -1; next }
    capture {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      match($0, /^[[:space:]]*/)
      cur = RLENGTH
      if (indent == -1) indent = cur
      if (cur < indent) { capture = 0; next }
      print substr($0, indent + 1)
    }
  ' "$1"
}
step="$work/step.sh"
extract_step_body "$HERE/action.yml" | sed "s#\${{ github.action_path }}#$HERE#g" > "$step"

run_step() {
  set +e
  OUT=$(env INPUT_AGENT_ROOTS="$1" INPUT_SKILL_ROOTS="$2" INPUT_AGENT_WORD_CAP=200 \
    INPUT_ALLOW="" INPUT_REPORT_ONLY="$3" bash -e "$step" 2>&1)
  RC=$?
  set -e
}
run_step "$work/clean/agents" "$work/clean/skills" false
expect "action step: a clean tree passes" 0 'clean'
run_step "$work/cap/agents $work/unknown/agents" "$work/unknown/skills" false
expect "action step: findings across two agent roots fail" 1 'unknown-skill'
run_step "$work/cap/agents" "" true
expect "action step: report-only turns findings into a notice" 0 'report-only is set'
run_step "$work/nope" "" true
expect "action step: report-only still fails a usage error" 2 'not a directory'
run_step "" "" false
expect "action step: no roots at all is a usage error" 2 'set agent-roots, skill-roots or both'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
