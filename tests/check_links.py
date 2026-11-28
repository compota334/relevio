#!/usr/bin/env python3
"""Check relevio's documentation links. Usage: check_links.py <repo root>

1. Every relative link in README.md and docs/*.md points at a file that
   exists and, with #anchor, at a heading that file has.
2. Every docs/*.md is linked from README.md (a doc nobody links is lost).
3. Every https://github.com/compota334/relevio/blob/main/<path>#anchor link
   in scripts/ and hooks/ (error messages users read) points at a file and
   heading of this repo: those links go out to people's terminals, where a
   moved section would break them silently.

Prints "ok", or "broken: <one entry per problem>".
"""
import functools
import glob
import os
import re
import sys

ROOT = sys.argv[1]
REPO_URL = "https://github.com/compota334/relevio/blob/main/"


@functools.lru_cache(maxsize=None)
def anchors(path):
    """GitHub-style anchors of a Markdown file's headings (code blocks
    skipped). Approximation: GitHub's -1, -2 suffixes for repeated headings
    are not produced."""
    out, fence = set(), False
    for line in open(path, encoding="utf-8").read().split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        m = None if fence else re.match(r"^#{1,6} (.*)$", line)
        if m:
            out.add(re.sub(r"[^\w\- ]", "", m.group(1).strip().lower()).replace(" ", "-"))
    return out


def check_target(full, anchor):
    if not os.path.exists(full):
        return False
    return not anchor or not full.endswith(".md") or anchor in anchors(full)


def prose(text):
    """The text outside code blocks (indented fences included, as inside a
    list item): a link written in an example is not a link."""
    out, fence = [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if not fence:
            out.append(line)
    return "\n".join(out)


bad = []
docs = sorted(os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, "docs", "*.md")))
readme = open(os.path.join(ROOT, "README.md"), encoding="utf-8").read()

for f in ["README.md"] + docs:
    text = prose(open(os.path.join(ROOT, f), encoding="utf-8").read())
    for m in re.finditer(r"\]\(([^)\s]+)\)", text):
        target = m.group(1)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path, _, anchor = target.partition("#")
        full = os.path.normpath(os.path.join(ROOT, os.path.dirname(f), path)) if path else os.path.join(ROOT, f)
        if not check_target(full, anchor):
            bad.append(f + ": " + target)

linked = {os.path.normpath(m.group(1).partition("#")[0])
          for m in re.finditer(r"\]\(([^)\s]+)\)", prose(readme))}
for d in docs:
    if d not in linked:
        bad.append("README.md does not link " + d)

for f in sorted(glob.glob(os.path.join(ROOT, "scripts", "*")) + glob.glob(os.path.join(ROOT, "hooks", "*.sh"))):
    text = open(f, encoding="utf-8").read()
    for m in re.finditer(re.escape(REPO_URL) + r"([\w./-]+)(?:#([\w-]+))?", text):
        if not check_target(os.path.join(ROOT, m.group(1)), m.group(2)):
            bad.append(os.path.relpath(f, ROOT) + ": " + m.group(0))

print("ok" if not bad else "broken: " + ", ".join(bad))
