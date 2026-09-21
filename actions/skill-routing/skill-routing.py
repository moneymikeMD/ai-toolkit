#!/usr/bin/env python3
"""Rank SKILL.md descriptions against prompts and fail when two descriptions collide.

Usage:
  skill-routing.py [ROOT ...]              # ROOT is a dir, or LABEL=DIR
  skill-routing.py --list                  # discovered skills, one per line
  skill-routing.py --fixtures FILE         # prompt fixtures (JSON)
  skill-routing.py --allow FILE            # accepted collisions the repo owns
  skill-routing.py --similarity-error F    # collision error threshold (0.75)
  skill-routing.py --similarity-warn F     # collision warning threshold (0.50)
  skill-routing.py --rank1-floor F         # required rank-1 rate (1.0)
  skill-routing.py --top-k N               # a positive passes inside top N (1)
  skill-routing.py --report-only           # exit 0 on violations, not on misuse
  skill-routing.py --selftest              # built-in fixture checks

Deterministic and zero-token: stemmed TF-IDF cosine, python3 stdlib only, no
model call, so it can run on every push. It does not replace `claude plugin
eval`, which asserts real routing against a live model and costs tokens.

THE RULE THAT COMES WITH IT: when a prompt routes to the wrong skill, fix the
skill's description. Never reword the prompt to make the check pass — the
prompt is the user, and the user does not get patched.

A skill id is LABEL/DIRNAME, where LABEL defaults to the basename of the root
it was found under. Pass LABEL=DIR to pin it across checkout layouts.

Fixture file (JSON):
  {"positives": [{"prompt": "...", "skill": "nw/session-start"}],
   "negatives": [{"prompt": "...", "skill": "nw/grill", "owner": "nw/to-issues"}]}
A positive must rank its own skill inside top-k. A negative names a skill the
prompt must NOT rank first, and the owner that must outrank it.

Allow file (JSON): {"collisions": [["a/x", "b/x"]]} — pairs the consuming repo
has accepted, the per-repo half of the generic rule in this action.

Exit: 0 clean, 1 violations found, 2 bad usage.
"""

import json
import math
import os
import re
import sys

SIMILARITY_ERROR = 0.75
SIMILARITY_WARN = 0.50
RANK1_FLOOR = 1.0
TOP_K = 1

SKIP_SUBSTRINGS = ("/node_modules/", "/.git/", "/worktrees/", "/fixtures/")

STOPWORDS = frozenset(
    """a about an and any anything are as at be before been being but by can do does
    for from has have how i if in into is it its just like may must no not
    of on one only or other our out over own per should so some such than that
    the their them then there these they this those through to under until up
    use used uses using very was way we what when where which while who why
    will with within without would you your""".split()
)

WORD = re.compile(r"[a-z0-9]+")
FRONTMATTER = re.compile(r"\A---\s*\n(.*?)\n---\s*(?:\n|\Z)", re.S)


def _m(stem, vowels="aeiou"):
    form = "".join("v" if c in vowels or (c == "y" and i and stem[i - 1] not in vowels)
                   else "c" for i, c in enumerate(stem))
    return form.count("vc")


def _has_vowel(stem):
    return any(c in "aeiou" for c in stem) or "y" in stem[1:]


def _double(stem):
    return len(stem) > 1 and stem[-1] == stem[-2] and stem[-1] not in "aeiou"


def _cvc(stem):
    if len(stem) < 3:
        return False
    a, b, c = stem[-3], stem[-2], stem[-1]
    return (a not in "aeiou" and b in "aeiouy" and c not in "aeiouwxy")


STEP2 = [
    ("ational", "ate"), ("tional", "tion"), ("enci", "ence"), ("anci", "ance"),
    ("izer", "ize"), ("abli", "able"), ("alli", "al"), ("entli", "ent"),
    ("eli", "e"), ("ousli", "ous"), ("ization", "ize"), ("ation", "ate"),
    ("ator", "ate"), ("alism", "al"), ("iveness", "ive"), ("fulness", "ful"),
    ("ousness", "ous"), ("aliti", "al"), ("iviti", "ive"), ("biliti", "ble"),
]
STEP3 = [
    ("icate", "ic"), ("ative", ""), ("alize", "al"), ("iciti", "ic"),
    ("ical", "ic"), ("ful", ""), ("ness", ""),
]
STEP4 = [
    "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment",
    "ent", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
]


def stem(word):
    """Porter-stemmed form of an already-lowercased ASCII word."""
    if len(word) <= 2 or not word.isalpha():
        return word
    w = word
    if w.endswith("sses"):
        w = w[:-2]
    elif w.endswith("ies"):
        w = w[:-2]
    elif w.endswith("ss"):
        pass
    elif w.endswith("s"):
        w = w[:-1]

    if w.endswith("eed"):
        if _m(w[:-3]) > 0:
            w = w[:-1]
    else:
        for suf in ("ed", "ing"):
            if w.endswith(suf) and _has_vowel(w[: -len(suf)]):
                w = w[: -len(suf)]
                if w.endswith(("at", "bl", "iz")):
                    w += "e"
                elif _double(w) and not w.endswith(("l", "s", "z")):
                    w = w[:-1]
                elif _m(w) == 1 and _cvc(w):
                    w += "e"
                break

    if w.endswith("y") and _has_vowel(w[:-1]):
        w = w[:-1] + "i"

    for suf, rep in STEP2:
        if w.endswith(suf):
            if _m(w[: -len(suf)]) > 0:
                w = w[: -len(suf)] + rep
            break
    for suf, rep in STEP3:
        if w.endswith(suf):
            if _m(w[: -len(suf)]) > 0:
                w = w[: -len(suf)] + rep
            break
    for suf in sorted(STEP4, key=len, reverse=True):
        if w.endswith(suf):
            base = w[: -len(suf)]
            if _m(base) > 1 and (suf not in ("ion",) or base.endswith(("s", "t"))):
                w = base
            break
    if w.endswith("ion") and _m(w[:-3]) > 1 and w[:-3].endswith(("s", "t")):
        w = w[:-3]

    if w.endswith("e"):
        base = w[:-1]
        if _m(base) > 1 or (_m(base) == 1 and not _cvc(base)):
            w = base
    if _m(w) > 1 and _double(w) and w.endswith("l"):
        w = w[:-1]
    return w


def tokenize(text):
    out = []
    for raw in WORD.findall(text.lower()):
        if raw in STOPWORDS or len(raw) < 2:
            continue
        s = stem(raw)
        if s and s not in STOPWORDS:
            out.append(s)
    return out


def parse_frontmatter(text):
    m = FRONTMATTER.match(text)
    if not m:
        return {}
    fields, key = {}, None
    for line in m.group(1).splitlines():
        head = re.match(r"^([A-Za-z0-9_-]+):\s?(.*)$", line)
        if head:
            key = head.group(1)
            fields[key] = head.group(2).strip()
        elif key and line.startswith((" ", "\t")):
            fields[key] = (fields[key] + " " + line.strip()).strip()
        elif not line.strip():
            continue
        else:
            key = None
    for k, v in list(fields.items()):
        if len(v) > 1 and v[0] == v[-1] and v[0] in "'\"":
            fields[k] = v[1:-1]
    return fields


def discover(roots):
    """Every SKILL.md under each root as (id, path, name, description) tuples,
    plus the (id, first path, second path) triples a later file lost a clash on."""
    skills, seen, dupes = [], {}, []
    for label, root in roots:
        root = os.path.abspath(root)
        for dirpath, dirnames, names in os.walk(root):
            dirnames[:] = [d for d in sorted(dirnames) if d not in (".git", "node_modules")]
            if "SKILL.md" not in names:
                continue
            path = os.path.join(dirpath, "SKILL.md")
            if any(s in path + "/" for s in SKIP_SUBSTRINGS):
                continue
            try:
                text = open(path, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            fm = parse_frontmatter(text)
            name = fm.get("name") or os.path.basename(dirpath)
            sid = f"{label}/{name}"
            if sid in seen:
                dupes.append((sid, seen[sid], path))
                continue
            seen[sid] = path
            skills.append((sid, path, name, fm.get("description", "")))
    return sorted(skills), sorted(dupes)


def build_index(docs):
    """(idf, vectors) for a list of token lists, L2-normalised tf-idf."""
    n = len(docs)
    df = {}
    for toks in docs:
        for t in set(toks):
            df[t] = df.get(t, 0) + 1
    idf = {t: math.log((n + 1) / (d + 1)) + 1.0 for t, d in df.items()}
    vectors = []
    for toks in docs:
        tf = {}
        for t in toks:
            tf[t] = tf.get(t, 0) + 1
        vec = {t: (1.0 + math.log(c)) * idf[t] for t, c in tf.items()}
        norm = math.sqrt(sum(v * v for v in vec.values())) or 1.0
        vectors.append({t: v / norm for t, v in vec.items()})
    return idf, vectors


def query_vector(tokens, idf):
    tf = {}
    for t in tokens:
        if t in idf:
            tf[t] = tf.get(t, 0) + 1
    vec = {t: (1.0 + math.log(c)) * idf[t] for t, c in tf.items()}
    norm = math.sqrt(sum(v * v for v in vec.values())) or 1.0
    return {t: v / norm for t, v in vec.items()}


def cosine(a, b):
    if len(a) > len(b):
        a, b = b, a
    return sum(v * b.get(t, 0.0) for t, v in a.items())


def rank(prompt, ids, vectors, idf):
    q = query_vector(tokenize(prompt), idf)
    scored = [(cosine(q, v), ids[i]) for i, v in enumerate(vectors)]
    scored.sort(key=lambda p: (-p[0], p[1]))
    return scored


def collisions(ids, vectors, error, warn, allowed):
    out = []
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            s = cosine(vectors[i], vectors[j])
            if s < warn:
                continue
            pair = tuple(sorted((ids[i], ids[j])))
            tier = "error" if s >= error else "warn"
            if pair in allowed:
                tier = "allowed"
            out.append((s, pair, tier))
    out.sort(key=lambda r: -r[0])
    return out


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as exc:
        print(f"skill-routing: cannot read {what} {path}: {exc}", file=sys.stderr)
        raise SystemExit(2)
    except json.JSONDecodeError as exc:
        print(f"skill-routing: {what} {path} is not valid JSON: {exc}", file=sys.stderr)
        raise SystemExit(2)


def evaluate(skills, fixtures, error, warn, allowed, floor, top_k):
    """Collision rows, fixture rows and a failure count for one workspace."""
    ids = [s[0] for s in skills]
    docs = [tokenize(s[3]) for s in skills]
    idf, vectors = build_index(docs)

    coll = collisions(ids, vectors, error, warn, allowed)
    known = set(ids)
    rows, failures = [], 0
    seen_positives, rank1_hits = 0, 0

    for case in fixtures.get("positives", []):
        want, prompt = case["skill"], case["prompt"]
        seen_positives += 1
        if want not in known:
            rows.append(("positive", prompt, want, None, 0.0, "UNKNOWN SKILL"))
            failures += 1
            continue
        scored = rank(prompt, ids, vectors, idf)
        order = [sid for score, sid in scored if score > 0.0]
        top = order[0] if order else None
        if want in order:
            pos = order.index(want) + 1
            ok = pos <= top_k
            if pos == 1:
                rank1_hits += 1
            note = f"rank {pos}" + ("" if ok else " MISS")
        else:
            ok = False
            note = "no term overlap MISS"
        rows.append(("positive", prompt, want, top, scored[0][0] if order else 0.0,
                     note))
        if not ok:
            failures += 1

    for case in fixtures.get("negatives", []):
        avoid, owner, prompt = case["skill"], case["owner"], case["prompt"]
        if avoid not in known or owner not in known:
            rows.append(("negative", prompt, owner, None, 0.0, "UNKNOWN SKILL"))
            failures += 1
            continue
        scored = rank(prompt, ids, vectors, idf)
        order = [sid for score, sid in scored if score > 0.0]
        top = order[0] if order else None
        if owner not in order:
            ok, note = False, "no term overlap MISS"
        else:
            ok = avoid not in order or order.index(owner) < order.index(avoid)
            note = ("owner outranks " if ok else "OUTRANKED BY ") + avoid
        rows.append(("negative", prompt, owner, top, scored[0][0] if order else 0.0,
                     note))
        if not ok:
            failures += 1

    rank1 = rank1_hits / seen_positives if seen_positives else 1.0
    if rank1 < floor:
        failures += 1
    failures += sum(1 for s, _, tier in coll if tier == "error")
    return coll, rows, rank1, failures


def report(skills, coll, rows, rank1, floor, error, warn, top_k):
    print(f"skill-routing: {len(skills)} skill(s) discovered")
    if coll:
        print(f"\nDescription collisions (warn>={warn:.2f}, error>={error:.2f}):")
        for s, (a, b), tier in coll:
            mark = {"error": "ERROR", "warn": "warn ", "allowed": "allow"}[tier]
            print(f"  {mark} {s:.3f}  {a}  <->  {b}")
    else:
        print(f"\nNo description pair at or above the {warn:.2f} warning threshold.")
    if rows:
        print(f"\nPrompt fixtures (top-k={top_k}):")
        for kind, prompt, want, top, score, note in rows:
            flag = "FAIL" if ("MISS" in note or "OUTRANKED" in note
                              or "UNKNOWN" in note) else "ok  "
            short = prompt if len(prompt) <= 58 else prompt[:55] + "..."
            print(f"  {flag} [{kind[:3]}] {short}")
            print(f"        want {want} | top {top} ({score:.3f}) | {note}")
        positives = [r for r in rows if r[0] == "positive"]
        if positives:
            print(f"\nrank-1 rate {rank1:.3f} over {len(positives)} positive(s) "
                  f"(floor {floor:.3f})")
    else:
        print("\nNo prompt fixtures given (--fixtures); collision check only.")
    print("\nA routing failure means fix the skill description, never the prompt.")


def parse_root(arg):
    if "=" in arg and not os.path.exists(arg):
        label, _, path = arg.partition("=")
        return label, path
    if "=" in arg:
        label, _, path = arg.partition("=")
        if os.path.isdir(path):
            return label, path
    return os.path.basename(os.path.abspath(arg)) or "root", arg


def selftest():
    import shutil
    import tempfile

    failed = ran = 0

    def check(name, got, want):
        nonlocal failed, ran
        ran += 1
        if got == want:
            print(f"ok   - {name}")
        else:
            print(f"FAIL - {name}: want {want!r}, got {got!r}")
            failed += 1

    check("stemmer folds inflections", stem("deployments"), stem("deployment"))
    check("stemmer folds verb forms", stem("redeploying"), stem("redeploy"))
    check("stemmer leaves short words", stem("vpn"), "vpn")
    check("tokenizer drops stopwords", tokenize("Load before the change"),
          [stem("load"), stem("change")])
    check("frontmatter reads a folded description",
          parse_frontmatter("---\nname: x\ndescription: one\n  two\n---\nbody\n")
          .get("description"), "one two")

    work = tempfile.mkdtemp()
    try:
        def write(label, slug, desc):
            d = os.path.join(work, label, slug)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as fh:
                fh.write(f"---\nname: {slug}\ndescription: {desc}\n---\nbody\n")

        alpha = ("Redeploy a running container stack in the homelab, restart a "
                 "service, recreate it, and verify the change actually reached "
                 "the running container.")
        beta = ("Rotate and read credentials from the 1Password vault, edit an "
                "env template, and keep secrets out of argv and out of logs.")
        gamma = ("Write a session wrap-up note for whoever picks this work up "
                 "next, at the end of a session that did real work.")
        write("a", "redeploy", alpha)
        write("a", "secrets", beta)
        write("b", "handoff", gamma)

        roots = [("a", os.path.join(work, "a")), ("b", os.path.join(work, "b"))]
        skills, dupes = discover(roots)
        check("discovery finds every SKILL.md", len(skills), 3)
        check("skill ids are label-qualified", skills[0][0], "a/redeploy")
        check("no duplicate ids in a clean tree", dupes, [])

        fx = {"positives": [
            {"prompt": "restart the media stack container and verify it came back",
             "skill": "a/redeploy"},
            {"prompt": "rotate the vault credential in the env template",
             "skill": "a/secrets"},
        ]}
        _, rows, rank1, fails = evaluate(
            skills, fx, SIMILARITY_ERROR, SIMILARITY_WARN, set(), 1.0, 1)
        check("on-vocabulary positives rank 1", (rank1, fails), (1.0, 0))

        off = {"positives": [
            {"prompt": "the film library box is grumpy again, poke it",
             "skill": "a/redeploy"}]}
        _, rows, rank1, fails = evaluate(
            skills, off, SIMILARITY_ERROR, SIMILARITY_WARN, set(), 1.0, 1)
        check("a positive worded away from the description is a rank-1 miss",
              (rank1 < 1.0, fails > 0, any("MISS" in r[5] or "UNKNOWN" in r[5]
                                           for r in rows)),
              (True, True, True))

        neg = {"negatives": [
            {"prompt": "rotate the vault credential in the env template",
             "skill": "a/redeploy", "owner": "a/secrets"}]}
        _, _, _, fails = evaluate(
            skills, neg, SIMILARITY_ERROR, SIMILARITY_WARN, set(), 1.0, 1)
        check("a satisfied negative does not fail", fails, 0)

        bad_neg = {"negatives": [
            {"prompt": "restart the media stack container and verify it came back",
             "skill": "a/redeploy", "owner": "a/secrets"}]}
        _, _, _, fails = evaluate(
            skills, bad_neg, SIMILARITY_ERROR, SIMILARITY_WARN, set(), 1.0, 1)
        check("a violated negative fails", fails > 0, True)

        coll, _, _, fails = evaluate(
            skills, {}, SIMILARITY_ERROR, SIMILARITY_WARN, set(), 1.0, 1)
        check("distinct descriptions do not collide", (len(coll), fails), (0, 0))

        write("b", "redeploy-copy", alpha)
        skills2, _ = discover(roots)
        coll, _, _, fails = evaluate(
            skills2, {}, SIMILARITY_ERROR, SIMILARITY_WARN, set(), 1.0, 1)
        pairs = [p for _, p, tier in coll if tier == "error"]
        check("a verbatim description copy is an error-tier collision",
              (("a/redeploy", "b/redeploy-copy") in pairs, fails > 0), (True, True))

        coll, _, _, fails = evaluate(
            skills2, {}, SIMILARITY_ERROR, SIMILARITY_WARN,
            {("a/redeploy", "b/redeploy-copy")}, 1.0, 1)
        check("an allowed pair downgrades to allow and does not fail",
              ([t for _, _, t in coll], fails), (["allowed"], 0))

        shutil.rmtree(os.path.join(work, "b", "redeploy-copy"))
        skills3, _ = discover(roots)
        coll, _, _, fails = evaluate(
            skills3, {}, SIMILARITY_ERROR, SIMILARITY_WARN, set(), 1.0, 1)
        check("reverting the copy makes the check clean again",
              (len(coll), fails), (0, 0))

        # Two SKILL.md declaring the same name under one label is the worst
        # routing collision there is, and dedupe-on-id used to hide it.
        write(os.path.join("a", "nested"), "redeploy", alpha)
        skills4, dupes4 = discover(roots)
        check("an identical skill id under one label is reported, not dropped",
              (len(skills4), [d[0] for d in dupes4]), (3, ["a/redeploy"]))
        shutil.rmtree(os.path.join(work, "a", "nested"))

        deep = os.path.join(work, "deep")
        for i in range(12):
            write("deep", f"filler{i}",
                  "Restart the container stack and verify the service came "
                  f"back, variant {i} of this description.")
        deep_skills, _ = discover([("d", deep)])
        d_ids = [s[0] for s in deep_skills]
        d_idf, d_vecs = build_index([tokenize(s[3]) for s in deep_skills])
        deep_prompt = "restart the container stack and verify the service came back"
        d_order = [sid for score, sid in rank(deep_prompt, d_ids, d_vecs, d_idf)
                   if score > 0.0]
        _, _, deep_rank1, deep_fails = evaluate(
            deep_skills, {"positives": [{"prompt": deep_prompt,
                                         "skill": d_order[-1]}]},
            SIMILARITY_ERROR, 1.01, set(), 1.0, len(d_order))
        check("a two-digit rank does not count toward the rank-1 rate",
              (len(d_order) >= 10, deep_rank1 < 1.0, deep_fails > 0),
              (True, True, True))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(f"\n{ran} assertion(s), {ran - failed} passed")
    return 1 if failed else 0


def read_opt(args, flag, default, cast):
    if flag not in args:
        return default
    i = args.index(flag)
    if i + 1 >= len(args):
        print(f"skill-routing: {flag} needs a value", file=sys.stderr)
        raise SystemExit(2)
    try:
        return cast(args[i + 1])
    except ValueError:
        print(f"skill-routing: {flag} needs a number", file=sys.stderr)
        raise SystemExit(2)


def main(argv):
    args = argv[1:]
    if "--selftest" in args:
        return selftest()

    valued = {"--similarity-error", "--similarity-warn", "--rank1-floor",
              "--top-k", "--fixtures", "--allow"}
    bare = {"--list", "--report-only", "--selftest"}
    for a in args:
        if a.startswith("--") and a not in valued and a not in bare:
            print(f"skill-routing: unknown flag: {a}", file=sys.stderr)
            return 2

    error = read_opt(args, "--similarity-error", SIMILARITY_ERROR, float)
    warn = read_opt(args, "--similarity-warn", SIMILARITY_WARN, float)
    floor = read_opt(args, "--rank1-floor", RANK1_FLOOR, float)
    top_k = read_opt(args, "--top-k", TOP_K, int)
    fixtures_path = read_opt(args, "--fixtures", "", str)
    allow_path = read_opt(args, "--allow", "", str)
    positional = [a for i, a in enumerate(args)
                  if not a.startswith("--") and not (i and args[i - 1] in valued)]
    roots = [parse_root(a) for a in positional] or [parse_root(".")]
    for _, path in roots:
        if not os.path.isdir(path):
            print(f"skill-routing: not a directory: {path}", file=sys.stderr)
            return 2

    skills, dupes = discover(roots)
    if "--list" in args:
        for sid, path, _, desc in skills:
            print(f"{sid}\t{len(tokenize(desc))} tok\t{path}")
        return 0
    if not skills:
        print("skill-routing: no SKILL.md found under "
              + ", ".join(p for _, p in roots), file=sys.stderr)
        return 2

    missing = [s[0] for s in skills if not s[3].strip()]
    fixtures = load_json(fixtures_path, "fixture file") if fixtures_path else {}
    allowed = set()
    if allow_path:
        for pair in load_json(allow_path, "allow file").get("collisions", []):
            allowed.add(tuple(sorted(pair)))

    coll, rows, rank1, failures = evaluate(
        skills, fixtures, error, warn, allowed, floor, top_k)
    report(skills, coll, rows, rank1, floor, error, warn, top_k)

    if missing:
        print("\nSkills with no description frontmatter, which can never be routed:",
              file=sys.stderr)
        for sid in missing:
            print(f"  {sid}", file=sys.stderr)
        failures += len(missing)

    if dupes:
        print("\nSkills claiming an id another SKILL.md already took, so only the "
              "first is reachable:", file=sys.stderr)
        for sid, first, second in dupes:
            print(f"  duplicate skill id {sid}: {first} and {second}",
                  file=sys.stderr)
        failures += len(dupes)

    if failures:
        print(f"\nskill-routing: {failures} failure(s).", file=sys.stderr)
        if "--report-only" in args:
            print("report-only is set, not failing the build", file=sys.stderr)
            return 0
        return 1
    print("\nskill-routing: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
