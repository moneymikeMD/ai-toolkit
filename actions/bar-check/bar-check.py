#!/usr/bin/env python3
"""Fail a diff that lowers a quality bar rather than meeting it.

Usage:
  bar-check.py --base REF [--head REF]   # diff REF...HEAD in this repo
  bar-check.py --diff FILE               # read a unified diff, "-" for stdin
  bar-check.py --allow-file PATH         # declared exceptions, default .bar-check-allow
  bar-check.py --report-only             # print findings, always exit 0
  bar-check.py --selftest                # built-in fixture checks

Five categories, all language-generic and all read off the diff:

  suppression        an added @ts-ignore, eslint-disable, # noqa, # type: ignore,
                     // nolint, #[allow(...)], @SuppressWarnings, # nosec and kin
  test-deleted       a test file deleted or moved out of a test path, or more
                     test declarations removed than added
  test-skipped       an added it.only, .skip, xit, @pytest.mark.skip, t.Skip, #[ignore]
  assertion-removed  a surviving test file that ends the diff with fewer assertions
  threshold-lowered  a numeric threshold in a config file edited downward

Diff-scoped by design: a violation already in the tree is not this branch's
problem, so only added and removed lines are read. An exception is declared in
the allow-file, never inferred, so a reviewer sees it in the diff that needs it.

Only downward threshold edits are reported. A ceiling that gets raised
(max-warnings 0 -> 10) is the same move in the other direction and is not
detected; the key would have to be known to be a ceiling.

Exit: 0 clean or report-only, 1 findings, 2 bad usage.
"""

import contextlib
import fnmatch
import io
import os
import re
import subprocess
import sys
import tempfile

CATEGORIES = (
    "suppression",
    "test-deleted",
    "test-skipped",
    "assertion-removed",
    "threshold-lowered",
)

DEFAULT_ALLOW_FILE = ".bar-check-allow"

GLOB_META = re.compile(r"[*?\[]")

SUPPRESSIONS = [
    ("ts-ignore", re.compile(r"@ts-(?:ignore|expect-error|nocheck)")),
    ("eslint-disable", re.compile(r"eslint-disable(?:-next-line|-line)?\b")),
    ("noqa", re.compile(r"#\s*noqa\b")),
    ("type-ignore", re.compile(r"#\s*(?:type|mypy)\s*:\s*ignore")),
    ("pylint-disable", re.compile(r"#\s*pylint\s*:\s*disable")),
    ("no-cover", re.compile(r"#\s*pragma\s*:\s*no\s*cover")),
    ("istanbul-ignore", re.compile(r"(?:istanbul|c8|v8)\s+ignore\b")),
    ("nolint", re.compile(r"//\s*nolint\b|//\s*lint:ignore\b")),
    ("rust-allow", re.compile(r"#!?\[allow\(")),
    ("suppresswarnings", re.compile(r"@SuppressWarnings\b")),
    ("nosec", re.compile(r"#\s*nosec\b")),
    ("shellcheck-disable", re.compile(r"shellcheck\s+disable=")),
    ("sonar-ignore", re.compile(r"NOSONAR\b")),
]

SKIPS = [
    ("only", re.compile(r"\b(?:it|test|describe|context|suite)\s*\.\s*only\s*\(")),
    ("skip", re.compile(r"\b(?:it|test|describe|context|suite)\s*\.\s*skip\s*\(")),
    ("x-prefixed", re.compile(r"\b(?:xit|xtest|xdescribe|fit|fdescribe)\s*\(")),
    ("pytest-skip", re.compile(r"@pytest\.mark\.(?:skip|skipif|xfail)\b")),
    ("unittest-skip", re.compile(r"@unittest\.skip")),
    ("pytest-skip-call", re.compile(r"\bpytest\.skip\s*\(")),
    ("go-skip", re.compile(r"\bt\.Skip(?:Now|f)?\s*\(")),
    ("rust-ignore", re.compile(r"#\[ignore\b")),
    ("junit-ignore", re.compile(r"@(?:Ignore|Disabled)\b")),
]

TEST_DECL = re.compile(
    r"^\s*(?:"
    r"(?:async\s+)?def\s+test\w*\s*\("
    r"|(?:async\s+)?(?:it|test)\s*(?:\.\w+)?\s*\("
    r"|func\s+Test\w+\s*\("
    r"|#\[(?:test|tokio::test)\]"
    r"|@Test\b"
    r")"
)

ASSERTION = re.compile(
    r"\bassert\b"
    r"|\bassert[A-Z_]\w*\s*\("
    r"|\bexpect\s*\("
    r"|\.should\b|\bshould\."
    r"|\b(?:EXPECT|ASSERT)_\w+\s*\("
    r"|\bt\.(?:Error|Fatal)f?\s*\("
    r"|\brequire\.\w+\s*\("
    r"|\bXCTAssert\w*\s*\("
)

TEST_PATH = re.compile(
    r"(?:^|/)(?:tests?|spec|specs|__tests__)/"
    r"|(?:^|/)test_[^/]+\.py$"
    r"|_test\.(?:py|go|rs|js|jsx|ts|tsx|rb)$"
    r"|\.(?:test|spec)\.(?:js|jsx|ts|tsx|mjs|cjs)$"
    r"|-selftest\.sh$"
    r"|_spec\.rb$"
    r"|(?:^|/)[A-Z]\w*Test\.java$"
)

CONFIG_EXT = (
    ".json",
    ".yml",
    ".yaml",
    ".toml",
    ".ini",
    ".cfg",
    ".conf",
    ".properties",
)

THRESHOLD_KEY = re.compile(
    r"(?i)cover|threshold|budget|floor|\bmin(?:imum)?\b|\bmin[_-]"
    r"|fail[_-]?under|statements|branches|functions|\blines\b"
    r"|score|percent|target|quality"
)

KEY_VALUE = re.compile(
    r"""^\s*[-*]?\s*["']?(?P<key>[A-Za-z_][\w.\- ]*?)["']?\s*[:=]\s*"""
    r"""["']?(?P<val>-?\d+(?:\.\d+)?)\s*%?["']?\s*,?\s*$"""
)

FLAG_VALUE = re.compile(r"--(?P<key>[A-Za-z][\w-]*)[= ](?P<val>-?\d+(?:\.\d+)?)")


class Hunk:
    def __init__(self):
        self.added = []
        self.removed = []


class FileDiff:
    def __init__(self, path):
        self.path = path
        self.old_path = path
        self.status = "modified"
        self.hunks = []

    @property
    def added(self):
        return [ln for h in self.hunks for ln in h.added]

    @property
    def removed(self):
        return [ln for h in self.hunks for ln in h.removed]


def parse_diff(text):
    """Parse a unified diff into per-file added and removed lines, by hunk."""
    files = []
    cur = None
    hunk = None
    new_lineno = 0

    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            m = re.match(r"diff --git a/(.+?) b/(.+)$", raw)
            cur = FileDiff(m.group(2) if m else raw)
            if m:
                cur.old_path = m.group(1)
            files.append(cur)
            hunk = None
            continue
        if cur is None:
            continue
        if raw.startswith("deleted file mode"):
            cur.status = "deleted"
            continue
        if raw.startswith("new file mode"):
            cur.status = "added"
            continue
        if raw.startswith("rename to "):
            cur.path = raw[len("rename to ") :].strip()
            continue
        if raw.startswith("rename from "):
            cur.old_path = raw[len("rename from ") :].strip()
            continue
        if raw.startswith("+++ "):
            target = raw[4:].strip()
            if target == "/dev/null":
                cur.status = "deleted"
            elif target.startswith("b/"):
                cur.path = target[2:]
            continue
        if raw.startswith("--- "):
            if raw[4:].strip() == "/dev/null":
                cur.status = "added"
            continue
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
        if m:
            hunk = Hunk()
            cur.hunks.append(hunk)
            new_lineno = int(m.group(1))
            continue
        if hunk is None:
            continue
        if raw.startswith("+"):
            hunk.added.append((new_lineno, raw[1:]))
            new_lineno += 1
        elif raw.startswith("-"):
            hunk.removed.append((new_lineno, raw[1:]))
        elif raw.startswith(" ") or raw == "":
            new_lineno += 1

    return files


def is_test_path(path):
    return bool(TEST_PATH.search(path))


def is_config_path(path):
    base = os.path.basename(path)
    if base.endswith(CONFIG_EXT):
        return True
    if base.startswith(".") and base.endswith("rc"):
        return True
    return "config" in base.lower()


def numeric_pairs(lines):
    out = {}
    for _, text in lines:
        m = KEY_VALUE.match(text)
        if m:
            key = m.group("key").strip()
            if THRESHOLD_KEY.search(key):
                out.setdefault(key, []).append(float(m.group("val")))
            continue
        for fm in FLAG_VALUE.finditer(text):
            key = fm.group("key")
            if THRESHOLD_KEY.search(key):
                out.setdefault(key, []).append(float(fm.group("val")))
    return out


def scan(files):
    findings = []

    for f in files:
        moved_out = (
            f.old_path != f.path
            and is_test_path(f.old_path)
            and not is_test_path(f.path)
        )
        if moved_out:
            findings.append(
                (
                    "test-deleted",
                    f.old_path,
                    0,
                    f"test file moved out of a test path -> {f.path}",
                )
            )

        if f.status == "deleted":
            if is_test_path(f.old_path):
                findings.append(
                    (
                        "test-deleted",
                        f.old_path,
                        0,
                        "test file deleted",
                    )
                )
            continue

        for lineno, text in f.added:
            for name, pat in SUPPRESSIONS:
                if pat.search(text):
                    findings.append(
                        ("suppression", f.path, lineno, f"{name}: {text.strip()[:90]}")
                    )
                    break
            for name, pat in SKIPS:
                if pat.search(text):
                    findings.append(
                        ("test-skipped", f.path, lineno, f"{name}: {text.strip()[:90]}")
                    )
                    break

        if is_test_path(f.path) and f.status != "added":
            removed_decls = sum(1 for _, t in f.removed if TEST_DECL.match(t))
            added_decls = sum(1 for _, t in f.added if TEST_DECL.match(t))
            if removed_decls > added_decls:
                findings.append(
                    (
                        "test-deleted",
                        f.path,
                        f.removed[0][0] if f.removed else 0,
                        f"{removed_decls - added_decls} test declaration(s) removed "
                        f"({removed_decls} out, {added_decls} in)",
                    )
                )
            removed_asserts = sum(1 for _, t in f.removed if ASSERTION.search(t))
            added_asserts = sum(1 for _, t in f.added if ASSERTION.search(t))
            if removed_asserts > added_asserts:
                findings.append(
                    (
                        "assertion-removed",
                        f.path,
                        f.removed[0][0] if f.removed else 0,
                        f"{removed_asserts - added_asserts} assertion(s) removed "
                        f"({removed_asserts} out, {added_asserts} in)",
                    )
                )

        if is_config_path(f.path):
            for h in f.hunks:
                before = numeric_pairs(h.removed)
                after = numeric_pairs(h.added)
                for key, olds in before.items():
                    if key not in after:
                        continue
                    old, new = min(olds), min(after[key])
                    if new < old:
                        line = next(
                            (n for n, t in h.added if KEY_VALUE.match(t) or key in t),
                            0,
                        )
                        findings.append(
                            (
                                "threshold-lowered",
                                f.path,
                                line,
                                f"{key}: {fmt(old)} -> {fmt(new)}",
                            )
                        )

    return findings


def fmt(v):
    return str(int(v)) if v == int(v) else str(v)


def read_allow_file(path):
    """Parse declared exceptions: '<category|*> <path-glob> [<substring>]' per line.

    A `#` opens a comment only as the line's first non-space character: four of
    the patterns a substring column has to quote begin with `#`.
    """
    rules = []
    if not path or not os.path.exists(path):
        return rules
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 2)
            if len(parts) < 2:
                print(
                    f"bar-check: {path}:{n}: need '<category> <path-glob> [<substring>]'",
                    file=sys.stderr,
                )
                raise SystemExit(2)
            category, glob = parts[0], parts[1]
            if category != "*" and category not in CATEGORIES:
                print(
                    f"bar-check: {path}:{n}: unknown category {category!r}; "
                    f"one of {', '.join(CATEGORIES)} or *",
                    file=sys.stderr,
                )
                raise SystemExit(2)
            rules.append((category, glob, parts[2].strip() if len(parts) > 2 else ""))
    return rules


def _match_segments(path_parts, glob_parts):
    if not glob_parts:
        return not path_parts
    if glob_parts[0] == "**":
        rest = glob_parts[1:]
        if not rest:
            return True
        return any(
            _match_segments(path_parts[i:], rest) for i in range(len(path_parts) + 1)
        )
    if not path_parts:
        return False
    return fnmatch.fnmatchcase(path_parts[0], glob_parts[0]) and _match_segments(
        path_parts[1:], glob_parts[1:]
    )


def path_matches(path, glob):
    """Match a repo-relative path against an allow-file path glob.

    `*` and `?` stop at `/` and `**` crosses it, so a rule naming one directory
    cannot silently cover the subtree beneath it. A glob with no wildcard at all
    names either that exact path or a directory, and a directory covers its
    subtree.
    """
    if _match_segments(path.split("/"), glob.split("/")):
        return True
    return not GLOB_META.search(glob) and path.startswith(glob.rstrip("/") + "/")


def allowed(finding, rules):
    category, path, _, evidence = finding
    for rule_cat, glob, substring in rules:
        if rule_cat not in ("*", category):
            continue
        if not path_matches(path, glob):
            continue
        if substring and substring not in evidence:
            continue
        return True
    return False


def git_diff(base, head):
    # Pinned: a caller's diff.noprefix, diff.mnemonicPrefix, diff.relative or
    # diff.external rewrites the paths parse_diff reads, and every allow-file
    # glob then stops matching.
    cmd = [
        "git",
        "-c",
        "diff.external=",
        "diff",
        "--no-ext-diff",
        "--no-color",
        "--no-relative",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--find-renames",
        f"{base}...{head}",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"bar-check: {' '.join(cmd)} failed: {proc.stderr.strip()}", file=sys.stderr)
        raise SystemExit(2)
    return proc.stdout


def report(findings, skipped, report_only):
    for category, path, line, evidence in findings:
        where = f"{path}:{line}" if line else path
        print(f"{where}: [{category}] {evidence}")
    if skipped:
        print(f"\nbar-check: {skipped} finding(s) covered by the allow-file")
    if not findings:
        print("bar-check: no quality bar lowered in this diff")
        return 0
    counts = {}
    for category, _, _, _ in findings:
        counts[category] = counts.get(category, 0) + 1
    summary = ", ".join(f"{k} x{v}" for k, v in sorted(counts.items()))
    print(
        f"\n{len(findings)} bar-weakening change(s): {summary}.\n"
        "A check that cannot pass is not made to pass by silencing it. Fix the\n"
        f"underlying problem, or declare the exception in {DEFAULT_ALLOW_FILE} so a\n"
        "reviewer sees it in the same diff.",
        file=sys.stderr,
    )
    if report_only:
        print("bar-check: report-only is set, not failing the build")
        return 0
    return 1


def run(diff_text, allow_rules, report_only, allow_path=None):
    files = parse_diff(diff_text)
    if allow_path:
        # The allow-file quotes the patterns it exempts, so scanning it would
        # report every entry the moment it is added.
        names = {os.path.normpath(allow_path)}
        if os.path.isabs(allow_path):
            names.add(os.path.relpath(allow_path, os.getcwd()))
        files = [f for f in files if not names & {f.path, f.old_path}]
    raw = scan(files)
    kept = [f for f in raw if not allowed(f, allow_rules)]
    return report(kept, len(raw) - len(kept), report_only)


def selftest():
    cases = []

    def case(name, diff, want_categories):
        cases.append((name, diff, sorted(want_categories)))

    def hunk(path, added=(), removed=(), header=None):
        body = "".join(f"-{t}\n" for t in removed) + "".join(f"+{t}\n" for t in added)
        head = header if header is not None else (
            f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n"
        )
        return head + "@@ -1,3 +1,3 @@\n" + body

    case(
        "an added @ts-ignore is a suppression",
        hunk("src/a.ts", added=["// @ts-ignore", "const x = y.z;"]),
        ["suppression"],
    )
    case(
        "a pre-existing @ts-ignore left alone is not reported",
        hunk("src/a.ts", added=["const x = 1;"]),
        [],
    )
    case(
        "removing a suppression is not reported",
        hunk("src/a.ts", removed=["// @ts-ignore"]),
        [],
    )
    case(
        "an added noqa is a suppression",
        hunk("src/a.py", added=["import os  # noqa: F401"]),
        ["suppression"],
    )
    case(
        "an added eslint-disable is a suppression",
        hunk("src/a.js", added=["/* eslint-disable no-unused-vars */"]),
        ["suppression"],
    )
    case(
        "an added it.only is a skipped test",
        hunk("tests/a.spec.js", added=["it.only('works', () => {"]),
        ["test-skipped"],
    )
    case(
        "an added pytest skip mark is a skipped test",
        hunk("tests/test_a.py", added=["@pytest.mark.skip(reason='flaky')"]),
        ["test-skipped"],
    )
    case(
        "a deleted test file is reported",
        "diff --git a/tests/test_a.py b/tests/test_a.py\ndeleted file mode 100644\n"
        "--- a/tests/test_a.py\n+++ /dev/null\n@@ -1,2 +0,0 @@\n"
        "-def test_a():\n-    assert 1 == 1\n",
        ["test-deleted"],
    )
    case(
        "a deleted non-test file is not reported",
        "diff --git a/src/a.py b/src/a.py\ndeleted file mode 100644\n"
        "--- a/src/a.py\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-x = 1\n",
        [],
    )
    case(
        "a removed test case in a surviving file is reported",
        hunk(
            "tests/test_a.py",
            removed=["def test_b():", "    assert f() == 2"],
        ),
        ["test-deleted", "assertion-removed"],
    )
    case(
        "a test file moved out of a test path is a deleted test",
        "diff --git a/tests/test_a.py b/_disabled/test_a.py.bak\n"
        "similarity index 100%\nrename from tests/test_a.py\n"
        "rename to _disabled/test_a.py.bak\n",
        ["test-deleted"],
    )
    case(
        "a test file renamed within a test path is not reported",
        "diff --git a/tests/test_a.py b/tests/test_b.py\n"
        "similarity index 100%\nrename from tests/test_a.py\nrename to tests/test_b.py\n",
        [],
    )
    case(
        "a non-test file moved anywhere is not reported",
        "diff --git a/src/a.py b/lib/a.py\n"
        "similarity index 100%\nrename from src/a.py\nrename to lib/a.py\n",
        [],
    )
    case(
        "renaming a test is net zero",
        hunk(
            "tests/test_a.py",
            removed=["def test_old():"],
            added=["def test_new():"],
        ),
        [],
    )
    case(
        "an assertion stripped from a surviving test is reported",
        hunk(
            "tests/test_a.py",
            removed=["    assert result == 42"],
            added=["    print(result)"],
        ),
        ["assertion-removed"],
    )
    case(
        "adding an assertion is not reported",
        hunk("tests/test_a.py", added=["    assert result == 42"]),
        [],
    )
    case(
        "a coverage threshold lowered in a config file is reported",
        hunk("jest.config.json", removed=['  "statements": 90,'], added=['  "statements": 70,']),
        ["threshold-lowered"],
    )
    case(
        "a coverage threshold raised is not reported",
        hunk("jest.config.json", removed=['  "statements": 70,'], added=['  "statements": 90,']),
        [],
    )
    case(
        "a fail-under flag lowered is reported",
        hunk("setup.cfg", removed=["addopts = --cov-fail-under 85"], added=["addopts = --cov-fail-under 60"]),
        ["threshold-lowered"],
    )
    case(
        "a non-threshold number lowered is not reported",
        hunk("app.json", removed=['  "timeout": 5000,'], added=['  "timeout": 3000,']),
        [],
    )
    case(
        "a threshold key that merely looks like min is not matched",
        hunk("app.json", removed=['  "admin_seats": 5,'], added=['  "admin_seats": 3,']),
        [],
    )
    case(
        "a threshold lowered outside a config file is not reported",
        hunk("src/a.py", removed=["MIN_COVERAGE = 90"], added=["MIN_COVERAGE = 70"]),
        [],
    )
    case(
        "the five categories in one diff are all named",
        hunk("src/a.ts", added=["// @ts-ignore"])
        + "diff --git a/tests/test_gone.py b/tests/test_gone.py\ndeleted file mode 100644\n"
        "--- a/tests/test_gone.py\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-def test_gone():\n"
        + hunk("tests/a.spec.js", added=["it.only('x', () => {"])
        + hunk("tests/test_b.py", removed=["    assert g() == 1"], added=["    g()"])
        + hunk(".nycrc", removed=['  "lines": 95,'], added=['  "lines": 50,']),
        [
            "suppression",
            "test-deleted",
            "test-skipped",
            "assertion-removed",
            "threshold-lowered",
        ],
    )

    failed = 0
    for name, diff, want in cases:
        got = sorted({c for c, _, _, _ in scan(parse_diff(diff))})
        if got == want:
            print(f"ok   - {name}")
        else:
            print(f"FAIL - {name}: want {want}, got {got}")
            failed += 1

    allow_cases = [
        (
            "a declared suppression is not reported",
            hunk("src/legacy/a.ts", added=["// @ts-ignore"]),
            [("suppression", "src/legacy/*.ts", "")],
            [],
        ),
        (
            "an allow-file glob does not cover a sibling directory",
            hunk("src/fresh/a.ts", added=["// @ts-ignore"]),
            [("suppression", "src/legacy/*.ts", "")],
            ["suppression"],
        ),
        (
            "an allow-file substring narrows the exception",
            hunk("src/legacy/a.ts", added=["// eslint-disable-next-line"]),
            [("suppression", "src/legacy/*.ts", "ts-ignore")],
            ["suppression"],
        ),
        (
            "a category-specific rule does not cover another category",
            hunk("tests/a.spec.js", added=["it.only('x', () => {"]),
            [("suppression", "tests/*", "")],
            ["test-skipped"],
        ),
    ]
    for name, diff, rules, want in allow_cases:
        kept = [f for f in scan(parse_diff(diff)) if not allowed(f, rules)]
        got = sorted({c for c, _, _, _ in kept})
        if got == sorted(want):
            print(f"ok   - {name}")
        else:
            print(f"FAIL - {name}: want {sorted(want)}, got {got}")
            failed += 1

    def rules_from(text):
        fd, tmp = tempfile.mkstemp(prefix="bar-check-allow-")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        try:
            return read_allow_file(tmp)
        finally:
            os.unlink(tmp)

    three_suppressions = hunk(
        "src/legacy/a.py",
        added=[
            "import os  # noqa: F401",
            "import sys  # type: ignore",
            "x = 1  # pylint: disable=all",
        ],
    )
    deep = hunk("src/legacy/deep/nested/a.ts", added=["// @ts-ignore"])

    parsed_cases = [
        (
            "a '#' in the substring column narrows the rule, it does not blank it",
            three_suppressions,
            "suppression src/legacy/*.py # noqa\n",
            ["pylint-disable", "type-ignore"],
        ),
        (
            "a substring written without its '#' still narrows the rule",
            three_suppressions,
            "suppression src/legacy/*.py noqa\n",
            ["pylint-disable", "type-ignore"],
        ),
        (
            "a '#' at the start of a line is still a comment",
            three_suppressions,
            "# suppression src/legacy/*.py\n  # indented too\n",
            ["noqa", "pylint-disable", "type-ignore"],
        ),
        (
            "a path glob's '*' does not cross a directory separator",
            deep,
            "suppression src/legacy/*.ts\n",
            ["ts-ignore"],
        ),
        (
            "'**' crosses separators where '*' does not",
            deep,
            "suppression src/legacy/**/*.ts\n",
            [],
        ),
        (
            "a directory named without a wildcard covers its subtree",
            deep,
            "suppression src/legacy\n",
            [],
        ),
        (
            "a directory glob covers its immediate children",
            hunk("src/legacy/a.ts", added=["// @ts-ignore"]),
            "suppression src/legacy/*\n",
            [],
        ),
    ]
    for name, diff, allow_text, want in parsed_cases:
        rules = rules_from(allow_text)
        kept = [f for f in scan(parse_diff(diff)) if not allowed(f, rules)]
        got = sorted(ev.split(":", 1)[0] for _, _, _, ev in kept)
        if got == sorted(want):
            print(f"ok   - {name}")
        else:
            print(f"FAIL - {name}: want {sorted(want)}, got {got}")
            failed += 1

    allow_file_diff = hunk(
        ".bar-check-allow", added=["suppression src/legacy/*.ts @ts-ignore"]
    )
    self_scan = scan(parse_diff(allow_file_diff))
    with contextlib.redirect_stdout(io.StringIO()):
        quiet = run(allow_file_diff, [], False, ".bar-check-allow")
    if self_scan and quiet == 0:
        print("ok   - the allow-file's own entries are not scanned as source")
    else:
        print(
            "FAIL - the allow-file's own entries are not scanned as source: "
            f"raw={len(self_scan)}, exit={quiet}"
        )
        failed += 1

    total = len(cases) + len(allow_cases) + len(parsed_cases) + 1
    print(f"\n{total} assertion(s), {total - failed} passed")
    return 1 if failed else 0


def take(args, flag, default=None):
    if flag not in args:
        return default, args
    i = args.index(flag)
    if i + 1 >= len(args):
        print(f"bar-check: {flag} needs a value", file=sys.stderr)
        raise SystemExit(2)
    value = args[i + 1]
    return value, args[:i] + args[i + 2 :]


def main(argv):
    args = argv[1:]
    if "--selftest" in args:
        return selftest()

    report_only = "--report-only" in args
    args = [a for a in args if a != "--report-only"]
    base, args = take(args, "--base")
    head, args = take(args, "--head", "HEAD")
    diff_path, args = take(args, "--diff")
    allow_path, args = take(args, "--allow-file", DEFAULT_ALLOW_FILE)

    unknown = [a for a in args if a.startswith("--")]
    if unknown:
        print(f"bar-check: unknown option(s): {' '.join(unknown)}", file=sys.stderr)
        return 2
    if bool(base) == bool(diff_path):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        print("bar-check: give exactly one of --base or --diff", file=sys.stderr)
        return 2

    if diff_path:
        diff_text = sys.stdin.read() if diff_path == "-" else open(
            diff_path, encoding="utf-8"
        ).read()
    else:
        diff_text = git_diff(base, head)

    return run(diff_text, read_allow_file(allow_path), report_only, allow_path)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
