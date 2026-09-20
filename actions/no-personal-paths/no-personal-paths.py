#!/usr/bin/env python3
"""Fail a build when a tracked file names somebody's home directory.

An absolute home directory is two bugs at once: in a public repo it names a
person, and anywhere it resolves nowhere on any other machine. A config that
carries one (an .mcp.json server path, a compose volume, an Alloy __path__) is
silently broken in every other checkout.

Usage:
  no-personal-paths.py [PATH ...] [--allow-file FILE] [--stats] [--format text|json]

  PATH         file or directory to check; default is every file git tracks
  --allow-file declared exceptions, gitignore-style globs, one per line,
               '#' comments and blank lines ignored
               (default: .github/personal-paths-allow, if it exists)
  --stats      print what was scanned and skipped, then exit 0
  --format     text (default) or json

Exit codes: 0 clean; 1 violations found; 2 usage or setup error.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# /Users/<name> and /home/<name>. The trailing boundary keeps '/home/' or a
# bare '/Users' from matching, which are not paths to anyone in particular.
PATTERN = re.compile(r"/(?:Users|home)/([A-Za-z0-9._][A-Za-z0-9._-]*)")

# Names that are never a person on a developer machine. 'runner' is the GitHub
# Actions home and appears legitimately in CI scripts and logs; the others are
# service accounts, not identities.
BUILTIN_ALLOWED_NAMES = frozenset({"runner", "root", "ubuntu", "linuxbrew"})

# Generated from commit messages by release-please, so a path quoted in a commit
# body would fail a build nobody can fix without rewriting history.
BUILTIN_ALLOWED_PATHS = ("CHANGELOG.md",)

DEFAULT_ALLOW_FILE = ".github/personal-paths-allow"


def die(msg):
    """Exit 2 — a setup error, distinct from exit 1, which means violations."""
    sys.stderr.write("no-personal-paths: %s\n" % msg)
    raise SystemExit(2)


def tracked_files():
    """Every path git tracks, or exit 2 when this is not a git checkout."""
    try:
        out = subprocess.run(["git", "ls-files", "-z"], capture_output=True,
                             check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        die("not a git checkout, and no PATH was given")
    return [p for p in out.decode("utf-8", "replace").split("\0") if p]


def walk(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                out.extend(os.path.join(root, f) for f in files)
        else:
            out.append(p)
    return out


def glob_to_regex(pattern):
    """Translate one gitignore-style glob to a regex.

    Supports '**' across separators, '*' and '?' within a segment, and a
    trailing '/' meaning everything beneath a directory. A pattern with no
    separator matches the basename at any depth, as gitignore does.
    """
    if pattern.endswith("/"):
        pattern += "**"
    anchored = "/" in pattern.rstrip("/")
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
            if pattern.startswith("/", i):
                i += 1
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    body = "".join(out)
    return re.compile(r"^" + body + r"$" if anchored
                      else r"^(?:.*/)?" + body + r"$")


def load_allow_file(path, explicit):
    if not os.path.exists(path):
        if explicit:
            die("--allow-file %s does not exist" % path)
        return [], []
    globs, names = [], []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            # 'name:<who>' declares a fake home directory used in fixtures,
            # so a fixture can live anywhere without opening a path glob.
            if line.startswith("name:"):
                names.append(line[len("name:"):].strip())
            else:
                globs.append((line, glob_to_regex(line)))
    return globs, names


def read_text(path):
    """Return a file's text, or None when it is binary or unreadable."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    if b"\0" in raw:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--allow-file", default=None)
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--format", default="text", choices=("text", "json"))
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()

    if args.help:
        sys.stdout.write(__doc__)
        return 0

    explicit = args.allow_file is not None
    allow_globs, allow_names = load_allow_file(
        args.allow_file or DEFAULT_ALLOW_FILE, explicit)
    allowed_names = BUILTIN_ALLOWED_NAMES | set(allow_names)

    files = walk(args.paths) if args.paths else tracked_files()

    findings, skipped_binary, skipped_allowed = [], 0, 0
    for path in sorted(set(files)):
        norm = path[2:] if path.startswith("./") else path
        if norm in BUILTIN_ALLOWED_PATHS:
            skipped_allowed += 1
            continue
        if any(rx.match(norm) for _pat, rx in allow_globs):
            skipped_allowed += 1
            continue
        text = read_text(path)
        if text is None:
            skipped_binary += 1
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for m in PATTERN.finditer(line):
                if m.group(1) in allowed_names:
                    continue
                findings.append({"file": norm, "line": n,
                                 "name": m.group(1), "match": m.group(0)})

    if args.stats:
        print("scanned %d file(s), skipped %d allowed, %d binary"
              % (len(set(files)) - skipped_allowed - skipped_binary,
                 skipped_allowed, skipped_binary))
        print("allowed names: %s" % ", ".join(sorted(allowed_names)))
        print("allow globs  : %s"
              % (", ".join(p for p, _ in allow_globs) or "none"))
        return 0

    if args.format == "json":
        print(json.dumps({"violations": findings}, indent=2))
    else:
        for f in findings:
            print("%s:%d: %s — a home directory names a person and resolves "
                  "nowhere else; use ${HOME} or $HOME"
                  % (f["file"], f["line"], f["match"]))
        if findings:
            names = sorted({f["name"] for f in findings})
            print("")
            print("no-personal-paths: %d violation(s) across %d file(s); "
                  "home directory name(s): %s"
                  % (len(findings), len({f["file"] for f in findings}),
                     ", ".join(names)))
            print("If one is a deliberate fixture, declare it in %s — either "
                  "a path glob or 'name:<who>'." % DEFAULT_ALLOW_FILE)
        else:
            print("no-personal-paths: %d file(s) clean" % len(set(files)))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
