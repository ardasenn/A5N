#!/usr/bin/env python3
"""Mechanical lint: broken links and orphan pages.

Called by weekly-lint.sh, but running it by hand does the same thing.
Writes lint-mech-<namespace>.md per namespace plus a summary on stdout.

    python3 scripts/lint-mech.py [output-directory]

Default output directory is <vault>/.a5n-logs/lint-mech, which is gitignored.

lint-report.md files are skipped on purpose. They quote broken link examples,
so scanning them produces findings that are not real.
"""
import re
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from config import load, ConfigError  # noqa: E402

try:
    VAULT = Path(load()["vault"]["path"])
except ConfigError as exc:
    sys.stderr.write(f"A5N config error:\n{exc}\n")
    raise SystemExit(1)
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else VAULT / ".a5n-logs" / "lint-mech"
SKIP_PARTS = {".git", ".obsidian", ".a5n-logs", "raw", "scripts", ".claude",
              "node_modules", "digests"}
# A namespace is any root directory holding a sources/ folder, so a new
# project is covered without touching this file.
PROJECTS = sorted(d.name for d in VAULT.iterdir() if (d / "sources").is_dir())

# The schema puts pages in a closed set of places, so that set is the scan
# boundary: anything else living in the directory is not a vault page. A
# deny list cannot do this job, because it has to grow every time a new
# kind of neighbour shows up. Most visible when the vault shares a
# directory with the A5N checkout itself: README.md, template/, docs/ and
# .github/ were scanned as pages and reported as dead links (targets like
# LICENSE do exist, they are simply not .md) and as orphans (nothing links
# to a contribution guide). fix-links.py draws the same boundary.
SCHEMA_DIRS = set(PROJECTS) | {"patterns", "chess-moves"}
SCHEMA_ROOT_FILES = {"index.md", "log.md", "GOALS.md", "CLAUDE.md", "AGENTS.md"}


def in_schema(rel) -> bool:
    if len(rel.parts) == 1:
        return rel.name in SCHEMA_ROOT_FILES
    return rel.parts[0] in SCHEMA_DIRS


# --- page inventory ---
pages = []
for p in sorted(VAULT.rglob("*.md")):
    rel = p.relative_to(VAULT)
    if any(part in SKIP_PARTS for part in rel.parts) or rel.name == "lint-report.md":
        continue
    if not in_schema(rel):
        continue
    pages.append(rel)

page_set = {str(r) for r in pages}
by_stem = {}
for rel in pages:
    by_stem.setdefault(rel.stem, []).append(rel)

MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+?)(?:#[^)]*)?\)")
WIKI_LINK = re.compile(r"\[\[([^\]|#]+?)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]")
INLINE_CODE = re.compile(r"`[^`]*`")
FENCE = re.compile(r"^\s*(```|~~~)")


def strip_code(text: str) -> list[str]:
    """Return lines with fenced blocks and inline `code` blanked out.

    Schema documents quote link syntax on purpose, so an example written as
    code is not a finding.
    """
    out, in_fence = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else INLINE_CODE.sub("", line))
    return out

def resolve(src: Path, target: str):
    """Resolve a link target to a vault page. None means broken."""
    t = target.strip()
    if t.startswith(("http://", "https://", "mailto:")):
        return "EXTERNAL"
    if "/" in t or t.endswith(".md"):
        cands = []
        for base in [(VAULT / src).parent, VAULT]:
            for suffix in ["", ".md"]:
                try:
                    q = (base / (t + suffix)).resolve()
                    q_rel = q.relative_to(VAULT)
                except (ValueError, OSError):
                    continue
                cands.append(q_rel)
        for c in cands:
            if str(c) in page_set:
                return str(c)
        # a link to a folder with no index page: not broken if it exists
        for base in [(VAULT / src).parent, VAULT]:
            try:
                q = (base / t).resolve()
                if q.is_dir():
                    return "DIR"
            except OSError:
                pass
        return None
    # bare wikilink: match on basename
    hits = by_stem.get(t, [])
    return str(hits[0]) if hits else None

broken = []      # (source, line, written target, basename rescue or None)
incoming = {}    # resolved page -> set of pages linking to it
for rel in pages:
    text = (VAULT / rel).read_text(encoding="utf-8", errors="replace")
    for ln, line in enumerate(strip_code(text), 1):
        targets = [m.group(1) for m in MD_LINK.finditer(line)]
        targets += [m.group(1) for m in WIKI_LINK.finditer(line)]
        for t in targets:
            r = resolve(rel, t)
            if r is None:
                stem = Path(t.strip()).stem
                hits = by_stem.get(stem, [])
                rescue = str(hits[0]) if hits else None
                broken.append((str(rel), ln, t, rescue))
                if rescue:
                    # the intent is clear, so count it and keep orphans honest
                    incoming.setdefault(rescue, set()).add(str(rel))
            elif r not in ("EXTERNAL", "DIR"):
                incoming.setdefault(r, set()).add(str(rel))

# --- orphan: no page links here ---
STRUCTURAL = {"index.md", "log.md", "lint-report.md", "CLAUDE.md",
              "AGENTS.md", "GOALS.md", "README.md"}
orphans = []
for rel in pages:
    s = str(rel)
    if rel.name in STRUCTURAL:
        continue
    if s not in incoming or not incoming[s]:
        orphans.append(s)

def proj_of(path_str: str) -> str:
    head = path_str.split("/")[0]
    return head if head in PROJECTS else "_root"

# --- one output file per namespace ---
groups = {}
for src, ln, t, rescue in broken:
    g = groups.setdefault(proj_of(src), {"wrongpath": [], "dead": [], "orphans": []})
    if rescue:
        g["wrongpath"].append((src, ln, t, rescue))
    else:
        g["dead"].append((src, ln, t))
for o in orphans:
    groups.setdefault(proj_of(o), {"wrongpath": [], "dead": [], "orphans": []})["orphans"].append(o)

today = date.today().isoformat()
OUT.mkdir(parents=True, exist_ok=True)
for proj in PROJECTS + ["_root"]:
    g = groups.get(proj, {"wrongpath": [], "dead": [], "orphans": []})
    lines = [f"# Mechanical lint findings: {proj} ({today})", ""]
    lines.append(f"## Dead links, target page does not exist in the vault ({len(g['dead'])})")
    lines += [f"- `{s}:{ln}` target: `{t}`" for s, ln, t in g["dead"]] or ["(none)"]
    lines.append("")
    lines.append(f"## Wrong path links, page exists but the relative path is off ({len(g['wrongpath'])})")
    lines += [f"- `{s}:{ln}` written: `{t}`, actual location: `{r}`" for s, ln, t, r in g["wrongpath"]] or ["(none)"]
    lines.append("")
    lines.append(f"## Orphan pages, nothing links here ({len(g['orphans'])})")
    lines += [f"- `{o}`" for o in g["orphans"]] or ["(none)"]
    (OUT / f"lint-mech-{proj}.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"pages scanned: {len(pages)}")
for proj in PROJECTS + ["_root"]:
    g = groups.get(proj, {"wrongpath": [], "dead": [], "orphans": []})
    print(f"{proj}: dead={len(g['dead'])} wrong-path={len(g['wrongpath'])} orphan={len(g['orphans'])}")
