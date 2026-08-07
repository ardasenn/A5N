#!/usr/bin/env python3
"""Repair wrong path links automatically.

Called by weekly-lint.sh, but running it by hand does the same thing.

Rewrites wikilinks and markdown links whose target page EXISTS but whose
relative path is wrong, for example `[[../entities/x]]` inside log.md becomes
`[[entities/x]]`. Deterministic and safe: dead links, whose target is nowhere
in the vault, are left alone for the lint report to raise, because fixing one
means guessing what was meant.

This is the only automatic edit in the whole system. It was verified on 258
links in one pass; the root cause is that ingest agents write `../` depth
inconsistently.

lint-report.md files are skipped since they quote broken links on purpose.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from config import load, ConfigError  # noqa: E402

try:
    VAULT = Path(load()["vault"]["path"])
except ConfigError as exc:
    sys.stderr.write(f"A5N config error:\n{exc}\n")
    raise SystemExit(1)
SKIP_PARTS = {".git", ".obsidian", ".a5n-logs", "raw", "scripts", ".claude",
              "node_modules", "digests"}

pages = []
for p in sorted(VAULT.rglob("*.md")):
    rel = p.relative_to(VAULT)
    if any(part in SKIP_PARTS for part in rel.parts) or rel.name == "lint-report.md":
        continue
    pages.append(rel)

page_set = {str(r) for r in pages}
by_stem = {}
for rel in pages:
    by_stem.setdefault(rel.stem, []).append(rel)

MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+?)(?:#[^)]*)?\)")
WIKI_LINK = re.compile(r"\[\[([^\]|#]+?)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]")

def resolve_ok(src: Path, target: str) -> bool:
    t = target.strip()
    if t.startswith(("http://", "https://", "mailto:")):
        return True
    if "/" in t or t.endswith(".md"):
        for base in [(VAULT / src).parent, VAULT]:
            for suffix in ["", ".md"]:
                try:
                    q = (base / (t + suffix)).resolve()
                    q_rel = q.relative_to(VAULT)
                except (ValueError, OSError):
                    continue
                if str(q_rel) in page_set:
                    return True
        for base in [(VAULT / src).parent, VAULT]:
            try:
                if (base / t).resolve().is_dir():
                    return True
            except OSError:
                pass
        return False
    return bool(by_stem.get(t))

INLINE_CODE = re.compile(r"`[^`]*`")
FENCE = re.compile(r"^\s*(```|~~~)")


def scannable(lines):
    """Blank out fenced blocks and inline `code` before looking for links.

    Schema documents quote link syntax on purpose, so an example written as
    code must not be mistaken for a real link.
    """
    out, in_fence = [], False
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else INLINE_CODE.sub("", line))
    return out


fixed, dead = 0, []
for rel in pages:
    fpath = VAULT / rel
    text = fpath.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    scan = scannable(lines)
    changed = False
    for i, line in enumerate(lines):
        targets = [m.group(1) for m in MD_LINK.finditer(scan[i])]
        targets += [m.group(1) for m in WIKI_LINK.finditer(scan[i])]
        for t in targets:
            if resolve_ok(rel, t):
                continue
            stem = Path(t.strip()).stem
            hits = by_stem.get(stem, [])
            if not hits:
                dead.append((str(rel), i + 1, t))
                continue  # dead link: leave it, the lint report raises it
            real = hits[0]
            correct = os.path.relpath(str(real), start=str(rel.parent))
            if not t.strip().endswith(".md"):
                correct = correct[:-3]  # a wikilink never carries the .md suffix
            new_line = re.sub(re.escape(t) + r"(?=[\]\|#\)])", correct, lines[i])
            if new_line != lines[i]:
                lines[i] = new_line
                changed = True
                fixed += 1
    if changed:
        fpath.write_text("".join(lines), encoding="utf-8")

print(f"links repaired: {fixed}")
print(f"dead links left alone: {len(dead)}")
for d in dead:
    print(f"  dead: {d[0]}:{d[1]} -> {d[2]}")
