#!/usr/bin/env python3
"""Ingest layer 2 verification: the ARTIFACT is checked, never a claim.

An earlier design grepped the agent's output for a result signature, and
every wrinkle in the claim's format, a backtick, a missing line, sent
finished work to rollback. This script does not look at the agent's words at
all. It inspects what the worker left on disk, so the worker prompt carries
no signature or format obligation.

Usage: python3 scripts/ingest-verify.py <project> <session_id>
cwd must be the vault root. Exit 0 means the unit is valid and the driver
commits it. Otherwise the reasons are on stdout, the driver rolls the unit
back, and the unit stays queued (state is the vault itself: raw present with
no id trace means queued), so it retries tomorrow on its own.

Checks, all mechanical:
 1. the working tree is dirty, the worker produced something
 2. every change sits on an allowed, in schema path:
      <project>/{sources/sessions,entities,concepts,decisions,bugs,syntheses,
      archive}/*.md, <project>/{index,log,lint-report}.md,
      patterns/*.md, root index.md, root log.md
    raw/ is NOT in the list: the worker may never write there (hard rule 1).
    An out of schema path is a rejection, so namespace isolation and "no
    scratch files in the vault" are now mechanical guarantees.
 3. a TRACE was left, in exactly one of the two shapes the queue accepts
    (the contract lives in ingest-discover.py's module docstring): a
    sources/sessions page containing the full raw path
    "raw/sessions/<id>.jsonl", or a "skip | <id>" line in <project>/log.md.
    A bare id mentioned anywhere else is NOT a trace: the old
    substring-anywhere test let mere log notes dequeue sessions twice.
 4. every sources page changed in this run that carries the raw path has
    complete frontmatter (title/tags/source/date/status) and its source:
    field points at the raw path
"""
import glob
import os
import re
import subprocess
import sys

REQUIRED_FM_KEYS = ("title", "tags", "source", "date", "status")


def changed_paths():
    # quotepath=off: with the default on, non-ASCII filenames (Turkish
    # slugs) arrive octal-escaped and quoted, so they never match the
    # glob-derived paths in the frontmatter check and silently skip it.
    out = subprocess.run(["git", "-c", "core.quotepath=off", "status",
                          "--porcelain"],
                         capture_output=True, text=True, check=True).stdout
    paths = []
    for line in out.splitlines():
        if not line.strip():
            continue
        p = line[3:]
        if " -> " in p:  # rename: verify the new path
            p = p.split(" -> ", 1)[1]
        paths.append(p.strip().strip('"'))
    return paths


def allowed(proj, p):
    q = re.escape(proj)
    patterns = (
        rf"^{q}/(sources/sessions|entities|concepts|decisions|bugs|syntheses|archive)/[^/]+\.md$",
        rf"^{q}/(index|log|lint-report)\.md$",
        r"^patterns/[^/]+\.md$",
        r"^(index|log)\.md$",
    )
    return any(re.match(rx, p) for rx in patterns)


def frontmatter_of(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if not text.startswith("---"):
        return None, text
    end = text.find("\n---", 3)
    return (text[:end] if end != -1 else None), text


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    proj, sid = sys.argv[1], sys.argv[2]
    problems = []

    dirt = changed_paths()
    if not dirt:
        problems.append("tree is clean, the worker produced nothing")
    for p in dirt:
        if not allowed(proj, p):
            problems.append(f"path not allowed by the schema: {p}")

    src_pages = glob.glob(os.path.join(proj, "sources", "sessions", "*.md"))
    log_path = os.path.join(proj, "log.md")
    log_text = ""
    if os.path.isfile(log_path):
        with open(log_path, encoding="utf-8", errors="replace") as f:
            log_text = f.read()

    raw_ref = f"raw/sessions/{sid}.jsonl"
    pages_with_id = []
    for sp in src_pages:
        with open(sp, encoding="utf-8", errors="replace") as f:
            if raw_ref in f.read():
                pages_with_id.append(sp)
    skip_trace = re.search(rf"skip \| {re.escape(sid)}\b", log_text)
    if not pages_with_id and not skip_trace:
        problems.append(
            f"no trace: no sources page contains '{raw_ref}' and "
            f"{proj}/log.md has no 'skip | {sid}' line. Write the source "
            f"page with that exact raw path in its source: field, or the "
            f"skip line with the id IN FULL.")

    # frontmatter integrity of pages that carry the id AND changed in this run
    dirt_set = set(dirt)
    for sp in pages_with_id:
        if sp not in dirt_set:
            continue
        fm, _ = frontmatter_of(sp)
        if fm is None:
            problems.append(f"frontmatter missing or unclosed: {sp}")
            continue
        for key in REQUIRED_FM_KEYS:
            if not re.search(rf"^{key}\s*:", fm, re.M):
                problems.append(f"frontmatter missing field '{key}': {sp}")
        if "raw/sessions/" not in fm:
            problems.append(f"source: field does not point at a raw path: {sp}")

    if problems:
        print(f"VERIFICATION REJECTED ({proj}/{sid}):")
        for pr in problems:
            print(f"  - {pr}")
        sys.exit(1)
    print(f"verification passed: {proj}/{sid} "
          f"({len(dirt)} files changed, {len(pages_with_id)} pages carry the id)")


if __name__ == "__main__":
    main()
