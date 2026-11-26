#!/usr/bin/env python3
"""Lint agent .md files and SKILL.md files for the faults that let a thin agent rot.

Usage:
  agent-skill-lint.py [--agent-root DIR]... [--skill-root DIR]...
                      [--agent-word-cap N] [--allow FILE] [--report-only]

Checks:
  agent-word-cap        an agent body (text after its frontmatter) is at most N
                        words (200), unless --allow maps its path to a reason
  unbacked-skill-load   a body that tells the agent to load, read or invoke a
                        named skill lists that skill in its `skills:` frontmatter
  unknown-skill         every un-namespaced `skills:` name is a skill found
                        under the --skill-root directories
  skill-frontmatter     each */SKILL.md has `name` and `description`
  skill-name            `name` equals the skill's directory name
  skill-description     description is at most 1024 characters, no < or >
  skill-length          SKILL.md is at most 500 lines

Agent roots are scanned for *.md; skill roots for */SKILL.md. The allow file is
JSON mapping an agent path, as found under its root, to the reason it may exceed
the cap. One finding per line as `path: rule: detail`. Exit 0 clean, 1 on any
finding (0 with --report-only), 2 on a usage error. python3 stdlib only.
"""

import argparse
import glob
import json
import os
import re
import sys

DESCRIPTION_MAX = 1024
SKILL_LINES_MAX = 500

LOAD_RE = re.compile(
    r"\b(?:load|loads|loading|read|reads|reading|invoke|invokes|invoking)\s+"
    r"(?:the\s+)?(`[^`\s]+`|[A-Za-z0-9][\w.-]*(?::[\w.-]+)?)\s+skill\b",
    re.IGNORECASE,
)


def split_frontmatter(text):
    """Return (frontmatter_lines, body) or (None, text) when there is none."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i], "\n".join(lines[i + 1:])
    return None, text


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    return v


def parse_frontmatter(lines):
    """Top-level keys only: scalars, block scalars (| >), flow and block lists."""
    out = {}
    i = 0
    key_re = re.compile(r"^([A-Za-z_][\w-]*):(?:\s+(.*))?$")
    while i < len(lines):
        m = key_re.match(lines[i])
        if not m:
            i += 1
            continue
        key, val = m.group(1), (m.group(2) or "").strip()
        i += 1
        nested = []
        while i < len(lines) and (lines[i].startswith((" ", "\t", "-")) or not lines[i].strip()):
            if lines[i].startswith("-") and key_re.match(lines[i]) is None and val:
                break
            nested.append(lines[i])
            i += 1
        if val[:1] in ("|", ">"):
            parts = [n.strip() for n in nested]
            out[key] = ("\n" if val[0] == "|" else " ").join(parts).strip()
        elif val.startswith("["):
            out[key] = [unquote(x) for x in val.strip("[]").split(",") if x.strip()]
        elif val:
            extra = " ".join(n.strip() for n in nested if n.strip())
            out[key] = unquote((val + " " + extra).strip() if extra else val)
        else:
            items = [unquote(n.strip()[1:]) for n in nested if n.strip().startswith("-")]
            out[key] = items if items else " ".join(n.strip() for n in nested).strip()
    return out


def as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return [x for x in v if x]
    return [x.strip() for x in str(v).split(",") if x.strip()]


def base_name(name):
    return name.split(":", 1)[-1]


def load_allow(path):
    if not path:
        return {}
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SystemExit("agent-skill-lint: cannot read --allow %s: %s" % (path, exc))
    if not isinstance(data, dict):
        raise SystemExit("agent-skill-lint: --allow %s must be a JSON object" % path)
    return {os.path.normpath(k): str(v or "").strip() for k, v in data.items()}


def lint_skills(roots, findings):
    names = set()
    for root in roots:
        for path in sorted(glob.glob(os.path.join(root, "*", "SKILL.md"))):
            dirname = os.path.basename(os.path.dirname(path))
            names.add(dirname)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            nlines = text.count("\n") + (0 if text.endswith("\n") or not text else 1)
            if nlines > SKILL_LINES_MAX:
                findings.append((path, "skill-length", "%d lines, limit %d" % (nlines, SKILL_LINES_MAX)))
            fm_lines, _ = split_frontmatter(text)
            fm = parse_frontmatter(fm_lines) if fm_lines is not None else {}
            name, desc = fm.get("name"), fm.get("description")
            if not name or not desc:
                missing = [k for k, v in (("name", name), ("description", desc)) if not v]
                findings.append((path, "skill-frontmatter", "missing %s" % ", ".join(missing)))
            if name and name != dirname:
                findings.append((path, "skill-name", "name %r does not match directory %r" % (name, dirname)))
            if desc:
                if len(desc) > DESCRIPTION_MAX:
                    findings.append((path, "skill-description",
                                     "%d characters, limit %d" % (len(desc), DESCRIPTION_MAX)))
                if "<" in desc or ">" in desc:
                    findings.append((path, "skill-description", "contains < or >"))
    return names


def lint_agents(roots, skill_names, cap, allow, findings):
    for root in roots:
        for path in sorted(glob.glob(os.path.join(root, "*.md"))):
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            fm_lines, body = split_frontmatter(text)
            if fm_lines is None:
                findings.append((path, "agent-frontmatter", "no frontmatter"))
                continue
            fm = parse_frontmatter(fm_lines)
            skills = as_list(fm.get("skills"))
            words = len(body.split())
            if words > cap and not allow.get(os.path.normpath(path)):
                findings.append((path, "agent-word-cap", "body is %d words, cap %d" % (words, cap)))
            listed = {s for s in skills} | {base_name(s) for s in skills}
            seen = set()
            for m in LOAD_RE.finditer(body):
                raw = m.group(1)
                ticked = raw.startswith("`")
                name = raw.strip("`")
                if not ticked and "-" not in name and ":" not in name:
                    continue
                if name in seen:
                    continue
                seen.add(name)
                if name not in listed and base_name(name) not in listed:
                    findings.append((path, "unbacked-skill-load",
                                     "body loads skill %r but `skills:` does not list it" % name))
            for s in skills:
                if ":" not in s and s not in skill_names:
                    findings.append((path, "unknown-skill",
                                     "`skills:` names %r, not found under any skill root" % s))


def main(argv):
    ap = argparse.ArgumentParser(description="Lint agent and SKILL.md files.")
    ap.add_argument("--agent-root", action="append", default=[], dest="agent_roots")
    ap.add_argument("--skill-root", action="append", default=[], dest="skill_roots")
    ap.add_argument("--agent-word-cap", type=int, default=200, dest="cap")
    ap.add_argument("--allow", default=None)
    ap.add_argument("--report-only", action="store_true", dest="report_only")
    args = ap.parse_args(argv)
    if args.cap < 1:
        ap.error("--agent-word-cap must be at least 1")
    for d in args.agent_roots + args.skill_roots:
        if not os.path.isdir(d):
            ap.error("not a directory: %s" % d)
    allow = load_allow(args.allow)
    findings = []
    skill_names = lint_skills(args.skill_roots, findings)
    lint_agents(args.agent_roots, skill_names, args.cap, allow, findings)
    for path, rule, detail in findings:
        print("%s: %s: %s" % (path, rule, detail))
    if not findings:
        print("agent-skill-lint: clean")
        return 0
    print("agent-skill-lint: %d finding(s)" % len(findings), file=sys.stderr)
    return 0 if args.report_only else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit as exc:
        if isinstance(exc.code, str):
            print(exc.code, file=sys.stderr)
            sys.exit(2)
        raise
