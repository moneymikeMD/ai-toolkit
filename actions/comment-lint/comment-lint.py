#!/usr/bin/env python3
"""Fail on comment blocks longer than the project's comment rule allows.

Usage:
  comment-lint.py [PATH ...]           # default: every tracked code file
  comment-lint.py --max-block N        # cap on any comment run below the header
  comment-lint.py --max-header N       # cap on the file header itself
  comment-lint.py --stats              # per-file comment ratio, no pass/fail
  comment-lint.py --selftest           # built-in fixture checks

Dependency-free: python3 stdlib only, one file, no config required. Drop it in
any repo. PATH may be a file or a directory; with no PATH it walks git ls-files.

The rule (CLAUDE.md): a file header documents usage and is capped at 80
lines; a public function's contract is 2 sentences; explaining a non-intuitive
choice is 2 lines, and a wrapped 2-sentence contract is allowed 4. Longer
reasoning belongs in memory-graph, docs/decisions.md
or a docs/known-issues/ entry.

Only a run of WHOLE-LINE comments is measured. Trailing comments after code,
heredoc bodies, YAML block scalars and Python docstrings are not comments for
this purpose and are skipped — a script that writes Markdown from a heredoc is
not commenting.

Exit: 0 clean, 1 violations found, 2 bad usage.
"""

import os
import re
import subprocess
import sys

MAX_BLOCK = 4
MAX_HEADER = 80

EXTENSIONS = (".sh", ".bash", ".py", ".yml", ".yaml", ".mjs", ".ts", ".js")
SKIP_SUBSTRINGS = ("/fixtures/", "node_modules/")

DIRECTIVE = re.compile(
    r"^\s*#\s*(shellcheck\b|noqa\b|type:\s|-\*-|!)|^#!"
)
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
BLOCK_SCALAR = re.compile(r":\s*[|>][-+0-9]*\s*$")


def is_comment(line):
    stripped = line.strip()
    return stripped.startswith("#") and not DIRECTIVE.match(line)


def comment_line_numbers(path, lines):
    """Line numbers (1-based) that count as whole-line comments."""
    ext = os.path.splitext(path)[1]
    out = []
    heredoc_end = None
    scalar_indent = None

    for i, raw in enumerate(lines, start=1):
        if heredoc_end is not None:
            if raw.strip() == heredoc_end:
                heredoc_end = None
            continue

        if scalar_indent is not None:
            indent = len(raw) - len(raw.lstrip())
            if raw.strip() and indent <= scalar_indent:
                scalar_indent = None
            else:
                continue

        if ext in (".yml", ".yaml") and BLOCK_SCALAR.search(raw):
            scalar_indent = len(raw) - len(raw.lstrip())
            continue

        if ext in (".sh", ".bash"):
            m = HEREDOC.search(raw)
            # A `<<WORD` with no matching terminator line is prose that merely
            # mentions a heredoc; honouring it would swallow the rest of the file.
            if m and not raw.strip().startswith("#"):
                word = m.group(2)
                if any(l.strip() == word for l in lines[i:]):
                    heredoc_end = word
                    continue

        if is_comment(raw):
            out.append(i)

    return out


def header_span(lines):
    """Line numbers belonging to the leading header block, which is exempt."""
    span = set()
    i = 0
    while i < len(lines) and (lines[i].startswith("#!") or not lines[i].strip()):
        span.add(i + 1)
        i += 1
    while i < len(lines) and lines[i].strip().startswith("#"):
        span.add(i + 1)
        i += 1
    return span


def violations(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (UnicodeDecodeError, OSError):
        return []

    exempt = header_span(lines)
    header_comments = sum(1 for n in exempt if is_comment(lines[n - 1]))
    over_header = []
    if header_comments > MAX_HEADER:
        over_header.append(
            (1, header_comments, "file header: usage and flags, not an essay")
        )
    nums = [n for n in comment_line_numbers(path, lines) if n not in exempt]

    found = []
    run = []
    for n in nums:
        if run and n == run[-1] + 1:
            run.append(n)
        else:
            if len(run) > MAX_BLOCK:
                found.append((run[0], len(run), lines[run[0] - 1].strip()))
            run = [n]
    if len(run) > MAX_BLOCK:
        found.append((run[0], len(run), lines[run[0] - 1].strip()))
    return over_header + found


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout.split()
    return [
        f
        for f in out
        if f.endswith(EXTENSIONS)
        and not any(s in "/" + f for s in SKIP_SUBSTRINGS)
        and os.path.exists(f)
    ]


def walk_dir(root):
    found = []
    for dirpath, _, names in os.walk(root):
        for n in sorted(names):
            p = os.path.join(dirpath, n)
            if n.endswith(EXTENSIONS) and not any(
                sub in "/" + p for sub in SKIP_SUBSTRINGS
            ):
                found.append(p)
    return found


def run_stats(paths):
    for p in sorted(paths):
        lines = open(p, encoding="utf-8").read().splitlines()
        if not lines:
            continue
        c = len(comment_line_numbers(p, lines))
        print(f"{c * 100 // len(lines):3d}%  {c:5d}/{len(lines):-6d}  {p}")
    return 0


def run_lint(paths):
    total = 0
    for p in sorted(paths):
        for start, length, first in violations(p):
            total += 1
            cap = MAX_HEADER if start == 1 and "file header" in first else MAX_BLOCK
            print(f"{p}:{start}: {length}-line comment block (max {cap})")
            print(f"    {first[:100]}")
    if total:
        print(
            f"\n{total} over-long comment block(s) "
            f"(header<={MAX_HEADER}, block<={MAX_BLOCK}).\n"
            f"A file header documents usage and caps at {MAX_HEADER} lines.\n"
            f"Below it: {MAX_BLOCK} lines max — 2 for a non-intuitive choice,\n"
            "2 sentences for a public contract. Longer reasoning belongs\n"
            "wherever this project keeps durable knowledge, not in the file.",
            file=sys.stderr,
        )
        return 1
    print(
        f"comment-lint: {len(paths)} file(s) clean "
        f"(header<={MAX_HEADER}, block<={MAX_BLOCK})"
    )
    return 0


def selftest():
    import tempfile

    cases = []

    def case(name, ext, body, want):
        cases.append((name, ext, body, want))

    case(
        "header of any length is exempt",
        ".sh",
        "#!/bin/bash\n# a\n# b\n# c\n# d\n# e\n# f\nexit 0\n",
        0,
    )
    over = "".join(f"# line {i}\n" for i in range(MAX_BLOCK + 1))
    at_cap = "".join(f"# line {i}\n" for i in range(MAX_BLOCK))
    case(
        "a block over the cap fails",
        ".sh",
        "#!/bin/bash\n# header\n\nexit 0\n" + over + "true\n",
        1,
    )
    case(
        "a block at the cap passes (2 sentences wrap)",
        ".sh",
        "#!/bin/bash\n# header\n\nexit 0\n" + at_cap + "true\n",
        0,
    )
    case(
        "markdown in a quoted heredoc is not a comment",
        ".sh",
        "#!/bin/bash\ncat <<'EOF'\n# title\n# a\n# b\n# c\n# d\nEOF\n",
        0,
    )
    case(
        "markdown in an unquoted heredoc is not a comment",
        ".sh",
        "#!/bin/bash\ncat <<EOF\n# title\n# a\n# b\n# c\n# d\nEOF\n",
        0,
    )
    case(
        "a <<WORD with no terminator is prose, not a heredoc",
        ".sh",
        "#!/bin/bash\n# header\n\nS=\"$(printf 'cat <<EOF')\"\n"
        + "".join(f"# line {i}\n" for i in range(MAX_BLOCK + 1))
        + "true\n",
        1,
    )
    case(
        "shellcheck directives never count",
        ".sh",
        "#!/bin/bash\n# header\n\nx=1\n# shellcheck disable=SC2034\n"
        "# shellcheck disable=SC2035\n# shellcheck disable=SC2086\n"
        "# shellcheck disable=SC2115\ntrue\n",
        0,
    )
    case(
        "a shell comment inside a yaml block scalar is skipped",
        ".yml",
        "jobs:\n  a:\n    steps:\n      - run: |\n          # a\n"
        "          # b\n          # c\n          # d\n          true\n",
        0,
    )
    yaml_over = "".join(f"  # line {i}\n" for i in range(MAX_BLOCK + 1))
    case(
        "a long yaml comment outside a scalar fails",
        ".yml",
        "name: x\non: push\n\njobs:\n" + yaml_over + "  a:\n"
        "    runs-on: ubuntu-latest\n",
        1,
    )
    case(
        "a python docstring is not a comment",
        ".py",
        '"""doc."""\n\n\ndef f():\n    """a\n    b\n    c\n    d\n    e\n    """\n'
        "    return 1\n",
        0,
    )
    case(
        "a header over the cap fails",
        ".sh",
        "#!/bin/bash\n" + "".join(f"# line {i}\n" for i in range(MAX_HEADER + 5)) + "true\n",
        1,
    )
    case(
        "a header at the cap passes",
        ".sh",
        "#!/bin/bash\n" + "".join(f"# line {i}\n" for i in range(MAX_HEADER)) + "true\n",
        0,
    )
    case(
        "consecutive blocks separated by code are measured apart",
        ".py",
        "# header\n\nx = 1\n# a\n# b\ny = 2\n# c\n# d\nz = 3\n",
        0,
    )

    failed = 0
    with tempfile.TemporaryDirectory() as d:
        for name, ext, body, want in cases:
            p = os.path.join(d, "t" + ext)
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(body)
            got = len(violations(p))
            if got == want:
                print(f"ok   - {name}")
            else:
                print(f"FAIL - {name}: want {want} violation(s), got {got}")
                failed += 1

    print(f"\n{len(cases)} assertion(s), {len(cases) - failed} passed")
    return 1 if failed else 0


def read_cap(args, flag, default):
    if flag in args:
        i = args.index(flag)
        if i + 1 >= len(args) or not args[i + 1].isdigit():
            print(f"comment-lint: {flag} needs a number", file=sys.stderr)
            raise SystemExit(2)
        return int(args[i + 1])
    return default


def main(argv):
    global MAX_BLOCK, MAX_HEADER
    args = argv[1:]
    if "--selftest" in args:
        return selftest()
    MAX_BLOCK = read_cap(args, "--max-block", MAX_BLOCK)
    MAX_HEADER = read_cap(args, "--max-header", MAX_HEADER)
    skip_next = {"--max-block", "--max-header"}
    args = [
        a
        for i, a in enumerate(args)
        if not (a in skip_next or (i and args[i - 1] in skip_next))
    ]
    stats = "--stats" in args
    given = [a for a in args if not a.startswith("--")]
    if not given:
        paths = tracked_files()
    else:
        paths = []
        for a in given:
            if os.path.isdir(a):
                paths.extend(walk_dir(a))
            elif a.endswith(EXTENSIONS):
                paths.append(a)
    if not paths:
        print("comment-lint: no code files to check", file=sys.stderr)
        return 2
    return run_stats(paths) if stats else run_lint(paths)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
