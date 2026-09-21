#!/bin/bash
#
# Selftest for bar-check. Diff-parsing assertions live in bar-check.py
# (--selftest, fixture-driven); this wrapper builds a real scratch git
# repository and runs the check over real branches, because a diff this
# tool will meet in CI is produced by git, not hand-written. It then runs
# the composite action's own step body under the runner's shell so the
# report-only and base-resolution guards are proven rather than assumed.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if python3 "$HERE/bar-check.py" --selftest; then
  unit_status=0
else
  unit_status=$?
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
failed=0
git init -q -b main "$repo"
git -C "$repo" config user.name "selftest"
git -C "$repo" config user.email "selftest@example.invalid"
git -C "$repo" config commit.gpgsign false

commit() { git -C "$repo" add -A && git -C "$repo" commit -qm "$1"; }

mkdir -p "$repo/src" "$repo/tests"
cat > "$repo/src/app.ts" <<'EOF'
export const total = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
EOF
cat > "$repo/tests/total.spec.js" <<'EOF'
describe('total', () => {
  it('sums', () => {
    expect(total([1, 2])).toBe(3);
  });
  it('handles empty', () => {
    expect(total([])).toBe(0);
  });
});
EOF
cat > "$repo/tests/test_edges.py" <<'EOF'
def test_negative():
    assert total([-1, 1]) == 0
EOF
cat > "$repo/jest.config.json" <<'EOF'
{
  "coverageThreshold": {
    "statements": 90,
    "branches": 85
  }
}
EOF
commit "base"
base="$(git -C "$repo" rev-parse HEAD)"

git -C "$repo" checkout -q -b weakened
printf '// @ts-ignore\nexport const bad: number = "1" as any;\n' >> "$repo/src/app.ts"
git -C "$repo" rm -q "$repo/tests/test_edges.py"
cat > "$repo/tests/total.spec.js" <<'EOF'
describe('total', () => {
  it.only('sums', () => {
    expect(total([1, 2])).toBe(3);
  });
  it('handles empty', () => {
    total([]);
  });
});
EOF
cat > "$repo/jest.config.json" <<'EOF'
{
  "coverageThreshold": {
    "statements": 50,
    "branches": 85
  }
}
EOF
commit "lower every bar at once"

run_check() {
  local label="$1" ref="$2" mode="$3" expect="$4"
  shift 4
  local out status
  out="$(cd "$repo" && python3 "$HERE/bar-check.py" --base "$base" --head "$ref" $mode 2>&1)" && status=0 || status=$?
  local ok=1
  if [ "$expect" = "zero" ] && [ "$status" -ne 0 ]; then ok=0; fi
  if [ "$expect" = "nonzero" ] && [ "$status" -eq 0 ]; then ok=0; fi
  local missing=()
  local want
  for want in "$@"; do
    grep -qF -- "$want" <<<"$out" || missing+=("$want")
  done
  if [ "$ok" -eq 1 ] && [ ${#missing[@]} -eq 0 ]; then
    echo "ok   - $label"
  else
    echo "FAIL - $label: exit $status, missing: ${missing[*]:-none}"
    printf '%s\n' "$out" | sed 's/^/       | /'
    failed=1
  fi
}

run_check "gate mode names all five categories and exits non-zero" weakened "" nonzero \
  "[suppression]" "[test-deleted]" "[test-skipped]" "[assertion-removed]" "[threshold-lowered]" \
  "src/app.ts" "tests/test_edges.py" "tests/total.spec.js" "jest.config.json" \
  "statements: 90 -> 50"

run_check "report-only mode names the same five and exits zero" weakened "--report-only" zero \
  "[suppression]" "[test-deleted]" "[test-skipped]" "[assertion-removed]" "[threshold-lowered]" \
  "report-only is set"

git -C "$repo" checkout -q main
git -C "$repo" checkout -q -b strengthened
cat >> "$repo/tests/test_edges.py" <<'EOF'


def test_large():
    assert total([10, 20]) == 30
EOF
cat > "$repo/jest.config.json" <<'EOF'
{
  "coverageThreshold": {
    "statements": 95,
    "branches": 85
  }
}
EOF
commit "add a test and raise the floor"

run_check "a branch that adds a test and raises a threshold exits zero in gate mode" \
  strengthened "" zero "no quality bar lowered"
run_check "a branch that adds a test and raises a threshold exits zero in report-only mode" \
  strengthened "--report-only" zero "no quality bar lowered"

git -C "$repo" checkout -q main
git -C "$repo" checkout -q -b declared
printf '// @ts-ignore\nexport const bad: number = "1" as any;\n' >> "$repo/src/app.ts"
commit "a suppression with nothing declared"

run_check "an undeclared suppression is reported" declared "" nonzero "[suppression]"

cat > "$repo/.bar-check-allow" <<'EOF'
# Upstream types are wrong here; tracked as TICKET-1.
suppression src/app.ts @ts-ignore
EOF
commit "declare the exception"

run_check "a suppression listed in the allow-file is not reported" declared "" zero \
  "no quality bar lowered" "covered by the allow-file"

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

step_body="$work/step.sh"
extract_step_body "$HERE/action.yml" \
  | sed "s#\${{ github.action_path }}#$HERE#g" \
  > "$step_body"

run_step() {
  local label="$1" ref="$2" report_only="$3" expect="$4" base_input="$5"
  local status
  git -C "$repo" checkout -q "$ref"
  if (cd "$repo" && INPUT_BASE="$base_input" INPUT_HEAD=HEAD \
        INPUT_ALLOW_FILE=.bar-check-allow INPUT_REPORT_ONLY="$report_only" \
        EVENT_BASE_SHA="" EVENT_BEFORE="" \
        bash --noprofile --norc -uo pipefail "$step_body" >/dev/null 2>&1)
  then
    status=0
  else
    status=$?
  fi
  if { [ "$expect" = "zero" ] && [ "$status" -eq 0 ]; } ||
     { [ "$expect" = "nonzero" ] && [ "$status" -ne 0 ]; }; then
    echo "ok   - $label"
  else
    echo "FAIL - $label: got exit $status"
    failed=1
  fi
}

run_step "composite step: report-only=true against five violations exits 0" \
  weakened "true" zero "$base"
run_step "composite step: report-only=false against five violations exits non-zero" \
  weakened "false" nonzero "$base"
run_step "composite step: report-only=false against a clean branch exits 0" \
  strengthened "false" zero "$base"
run_step "composite step: no resolvable base fails loudly rather than passing empty" \
  strengthened "false" nonzero ""

if [ "$unit_status" -ne 0 ] || [ "$failed" -ne 0 ]; then
  exit 1
fi
exit 0
