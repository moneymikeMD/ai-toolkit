#!/bin/bash
#
# Selftest for skill-routing. Ranker assertions live in skill-routing.py
# (--selftest, fixture-driven); this wrapper additionally runs the composite
# action's own step body under the runner's real shell invocation, against a
# scratch fixture tree, so the report-only guard and the roots/fixtures
# argument plumbing are proven rather than assumed.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if python3 "$HERE/skill-routing.py" --selftest; then
  ranker_status=0
else
  ranker_status=$?
fi

# Extracted from action.yml's own run: block rather than duplicated here,
# so this test breaks the moment the shipped step diverges from what it checks.
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step_body="$work/step.sh"
extract_step_body "$HERE/action.yml" \
  | sed "s#\${{ github.action_path }}#$HERE#g" \
  > "$step_body"

ALPHA='Redeploy a running container stack, restart a service, recreate it, and verify the change actually reached the running container.'
BETA='Rotate and read credentials from the password vault, edit an env template, and keep secrets out of argv and out of logs.'

write_skill() {
  mkdir -p "$work/$1/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\nbody\n' "$2" "$3" > "$work/$1/$2/SKILL.md"
}

write_skill a redeploy "$ALPHA"
write_skill a secrets "$BETA"

cat > "$work/fixtures.json" <<'JSON'
{
  "positives": [
    {"prompt": "restart the media stack container and verify it came back",
     "skill": "a/redeploy"},
    {"prompt": "rotate the vault credential in the env template",
     "skill": "a/secrets"}
  ]
}
JSON

cat > "$work/off-vocab.json" <<'JSON'
{
  "positives": [
    {"prompt": "the film library box is grumpy again, poke it",
     "skill": "a/redeploy"}
  ]
}
JSON

cat > "$work/allow.json" <<JSON
{"collisions": [["a/redeploy", "b/redeploy-copy"]]}
JSON

wrapper_failed=0

run_step() {
  local label="$1" expect="$2" report_only="$3" roots="$4" fixtures="${5:-}" allow="${6:-}"
  local got
  if INPUT_ROOTS="$roots" INPUT_FIXTURES="$fixtures" INPUT_ALLOW="$allow" \
     INPUT_SIMILARITY_ERROR=0.75 INPUT_SIMILARITY_WARN=0.50 \
     INPUT_RANK1_FLOOR=1.0 INPUT_TOP_K=1 INPUT_REPORT_ONLY="$report_only" \
     bash --noprofile --norc -eo pipefail "$step_body" >"$work/out.txt" 2>&1
  then
    got=0
  else
    got=$?
  fi
  if { [ "$expect" = zero ] && [ "$got" -eq 0 ]; } ||
     { [ "$expect" = nonzero ] && [ "$got" -ne 0 ]; }; then
    echo "ok   - $label"
  else
    echo "FAIL - $label: got exit $got"
    sed 's/^/        /' "$work/out.txt"
    wrapper_failed=1
  fi
}

roots="a=$work/a b=$work/b"
mkdir -p "$work/b"

run_step "composite step: distinct descriptions and matching prompts exit 0" \
  zero false "$roots" "$work/fixtures.json"

run_step "composite step: a prompt worded away from the description exits non-zero" \
  nonzero false "$roots" "$work/off-vocab.json"

run_step "composite step: report-only=true on that same miss exits 0" \
  zero true "$roots" "$work/off-vocab.json"

write_skill b redeploy-copy "$ALPHA"

run_step "composite step: a verbatim description copy exits non-zero" \
  nonzero false "$roots"

if ! grep -q 'a/redeploy  <->  b/redeploy-copy' "$work/out.txt"; then
  echo "FAIL - the collision report names the offending pair"
  wrapper_failed=1
else
  echo "ok   - the collision report names the offending pair"
fi

run_step "composite step: an allow-listed collision exits 0" \
  zero false "$roots" "" "$work/allow.json"

run_step "composite step: report-only=true on a collision exits 0" \
  zero true "$roots"

rm -rf "${work:?}/b/redeploy-copy"

run_step "composite step: reverting the copy exits 0 again" \
  zero false "$roots"

# report-only is for violations (exit 1). A usage error (exit 2) means the
# check never ran, and masking it leaves a green job that proves nothing.
run_step "composite step: report-only does not mask a missing fixture file" \
  nonzero true "$roots" "$work/does-not-exist.json"

run_step "composite step: report-only does not mask a bad roots path" \
  nonzero true "a=$work/not-a-directory"

write_skill a/nested redeploy "$ALPHA"

run_step "composite step: a duplicate skill id exits non-zero" \
  nonzero false "$roots"

if ! grep -q 'duplicate skill id a/redeploy' "$work/out.txt"; then
  echo "FAIL - the report names the duplicated skill id"
  wrapper_failed=1
else
  echo "ok   - the report names the duplicated skill id"
fi

rm -rf "${work:?}/a/nested"

if python3 "$HERE/skill-routing.py" --report-onlyy "$work/a" >"$work/out.txt" 2>&1
then
  flag_status=0
else
  flag_status=$?
fi
if [ "$flag_status" -eq 2 ] && grep -q 'unknown flag: --report-onlyy' "$work/out.txt"
then
  echo "ok   - a mistyped flag exits 2 and names itself"
else
  echo "FAIL - a mistyped flag exits 2 and names itself: got exit $flag_status"
  sed 's/^/        /' "$work/out.txt"
  wrapper_failed=1
fi

# The reusable workflow has no caller yet, so a typo'd pass-through would
# surface only at the first repo that uses the whole-job form.
workflow="$HERE/../../.github/workflows/skill-routing.yml"
action_inputs="$(awk '/^inputs:/{c=1;next} /^[a-z]/{c=0}
  c && /^  [a-z0-9-]+:$/{gsub(/[ :]/,"");print}' "$HERE/action.yml" | sort)"
call_inputs="$(awk '/^    inputs:$/{c=1;next} /^jobs:/{c=0}
  c && /^      [a-z0-9-]+:$/{gsub(/[ :]/,"");print}' "$workflow" | sort)"
with_keys="$(awk '/^        with:$/{c=1;next}
  c && /^          [a-z0-9-]+:/{sub(/:.*/,"");gsub(/ /,"");print}' "$workflow" | sort)"
if [ -n "$action_inputs" ] && [ "$action_inputs" = "$call_inputs" ] &&
   [ "$action_inputs" = "$with_keys" ]; then
  echo "ok   - the reusable workflow passes through exactly the action's inputs"
else
  echo "FAIL - the reusable workflow passes through exactly the action's inputs"
  diff <(echo "$action_inputs") <(echo "$call_inputs") | sed 's/^/        call: /'
  diff <(echo "$action_inputs") <(echo "$with_keys") | sed 's/^/        with: /'
  wrapper_failed=1
fi

if [ "$ranker_status" -ne 0 ] || [ "$wrapper_failed" -ne 0 ]; then
  exit 1
fi
exit 0
