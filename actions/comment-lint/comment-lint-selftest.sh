#!/bin/bash
#
# Selftest for comment-lint. Linter assertions live in comment-lint.py
# (--selftest, fixture-driven); this wrapper additionally runs the
# composite action's own step body under the runner's real shell
# invocation, against a fixture tree with a known violation, so the
# report-only guard is proven rather than assumed.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if python3 "$HERE/comment-lint.py" --selftest; then
  linter_status=0
else
  linter_status=$?
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

fixture="$work/fixture"
mkdir -p "$fixture"
{
  echo '#!/bin/bash'
  echo '# header'
  echo 'echo hi'
  for i in 1 2 3 4 5; do echo "# line $i"; done
  echo 'true'
} > "$fixture/bad.sh"

wrapper_failed=0

run_step() {
  local report_only="$1" expect="$2" label="$3"
  if INPUT_PATH="$fixture" INPUT_MAX_HEADER=80 INPUT_MAX_BLOCK=4 \
       INPUT_REPORT_ONLY="$report_only" \
       bash --noprofile --norc -eo pipefail "$step_body" >/dev/null 2>&1
  then
    got=0
  else
    got=$?
  fi
  if [ "$expect" = "zero" ] && [ "$got" -eq 0 ]; then
    echo "ok   - $label"
  elif [ "$expect" = "nonzero" ] && [ "$got" -ne 0 ]; then
    echo "ok   - $label"
  else
    echo "FAIL - $label: got exit $got"
    wrapper_failed=1
  fi
}

run_step "true" "zero" "composite step under the runner's shell: report-only=true against a violation exits 0"
run_step "false" "nonzero" "composite step under the runner's shell: report-only=false against a violation exits non-zero"
run_step "" "nonzero" "composite step under the runner's shell: report-only unset against a violation exits non-zero"

if [ "$linter_status" -ne 0 ] || [ "$wrapper_failed" -ne 0 ]; then
  exit 1
fi
exit 0
