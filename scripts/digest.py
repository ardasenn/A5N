#!/usr/bin/env python3
"""Monthly value digest: what the vault accumulated, made visible.

The pipeline's "silence is success" rule is right operationally and wrong
as a product: a user who never sees what piles up cannot tell a working
system from a dead one, and quietly loses trust. Once a month this script
turns the vault's own history into one page of numbers.

Deterministic Python, no model call: the digest is free, instant, and
cannot hallucinate its statistics. Every number comes from the vault git
history or the pages themselves. A quiet month still produces a digest,
"0 sessions" is a health signal worth seeing, not noise.

Usage:
    python3 scripts/digest.py [YYYY-MM]

Default period is the PREVIOUS calendar month, because the scheduled run
fires on the 1st and reports on what just ended. Output is written to
<vault>/digests/YYYY-MM.md (overwriting: the digest is regenerable), and
its vault relative path is printed on stdout for the driver.

Headings come from a small en/tr string table picked by the vault
language. A deterministic script cannot translate, so any other language
falls back to English; the numbers carry the meaning either way.
"""
import datetime
import os
import re
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import load, ConfigError  # noqa: E402

SKIP_DIRS = {".git", ".obsidian", ".a5n-logs", "raw", ".claude",
             "node_modules", "digests"}
# Only knowledge pages count as "created". Structural files (indexes, logs,
# schema, reports) and setup scaffolding would otherwise inflate the first
# digest into fiction: a fresh vault "created" a dozen pages of nothing.
CATEGORIES = {"sources", "entities", "concepts", "decisions", "bugs",
              "syntheses", "archive"}
# Schema documents quote link syntax as examples; counting those as
# references put [[wikilink]] itself on the leaderboard once.
NOT_A_SOURCE = {"CLAUDE.md", "AGENTS.md", "lint-report.md"}
INGEST_RX = re.compile(r"^chore: ingest\(([^)]+)\)")
WIKI_RX = re.compile(r"\[\[([^\]|#]+)")
# skip lines only: "note |" lines record kept duplicates, not filter drops
SKIP_LINE_RX = re.compile(r"^## \[(\d{4}-\d{2})-\d{2}\] skip \|")
INLINE_CODE = re.compile(r"`[^`]*`")
FENCE = re.compile(r"^\s*(```|~~~)")

STRINGS = {
    "en": {
        "title": "{vault} digest, {period}",
        "h1": "# Digest: {period} (written {today})",
        "sessions": "## Sessions processed: {n}",
        "pages": "## Pages",
        "created": "created: {n}",
        "updated": "updated: {n}",
        "patterns": "## New cross project patterns ({n})",
        "top": "## Most referenced pages",
        "links": "{n} links",
        "skips": "## Sessions skipped: {n} (capture filters, or a worker's reasoned skip)",
        "health": "## Health",
        "quiet": ("No sessions were processed this month. If you did work "
                  "with your agents, the pipeline may be broken: check "
                  ".a5n-logs/ and run scripts/daily-ingest.sh by hand."),
        "ok": "The pipeline ran and committed work this month.",
        "none": "(none)",
    },
    "tr": {
        "title": "{vault} özeti, {period}",
        "h1": "# Aylık özet: {period} ({today} yazıldı)",
        "sessions": "## İşlenen oturum: {n}",
        "pages": "## Sayfalar",
        "created": "açılan: {n}",
        "updated": "güncellenen: {n}",
        "patterns": "## Yeni cross project pattern ({n})",
        "top": "## En çok referans alan sayfalar",
        "links": "{n} link",
        "skips": "## Atlanan oturum: {n} (yakalama süzgeçleri ya da işçinin gerekçeli kararı)",
        "health": "## Sağlık",
        "quiet": ("Bu ay hiç oturum işlenmedi. Ajanlarla çalıştıysan boru "
                  "hattı bozulmuş olabilir: .a5n-logs/ dizinine bak ve "
                  "scripts/daily-ingest.sh'yi elle koştur."),
        "ok": "Boru hattı bu ay çalıştı ve iş commit'ledi.",
        "none": "(yok)",
    },
}


def lang_of(cfg):
    lang = cfg["vault"]["language"].strip().lower()
    return "tr" if lang in ("turkish", "türkçe", "turkce", "tr") else "en"


def period_of(argv):
    if len(argv) > 1:
        try:
            start = datetime.date.fromisoformat(argv[1] + "-01")
        except ValueError:
            sys.exit(f"error: period must be YYYY-MM, got '{argv[1]}'")
    else:
        first_of_current = datetime.date.today().replace(day=1)
        start = (first_of_current - datetime.timedelta(days=1)).replace(day=1)
    if start.month == 12:
        nxt = start.replace(year=start.year + 1, month=1)
    else:
        nxt = start.replace(month=start.month + 1)
    return start, nxt


def git_lines(vault, args):
    r = subprocess.run(["git", "-C", vault] + args,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"error: git failed: {r.stderr.strip()}")
    return [ln for ln in r.stdout.splitlines() if ln.strip()]


def is_knowledge_page(path):
    parts = path.split("/")
    if parts[0] in ("patterns", "chess-moves") and len(parts) == 2:
        return True
    return len(parts) >= 3 and parts[1] in CATEGORIES


def changed_pages(vault, since, until, diff_filter):
    lines = git_lines(vault, [
        "log", f"--since={since} 00:00:00", f"--until={until} 00:00:00",
        f"--diff-filter={diff_filter}", "--name-only", "--pretty=format:"])
    return {p for p in lines if p.endswith(".md") and is_knowledge_page(p)}


def category_counts(pages):
    cats = Counter()
    for p in pages:
        parts = p.split("/")
        cats[parts[0] if len(parts) == 2 else parts[1]] += 1
    return cats


def strip_code(text):
    """Blank fenced blocks and inline code so quoted link examples in a
    page are not counted as references."""
    out, in_fence = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else INLINE_CODE.sub("", line))
    return "\n".join(out)


def skip_count(vault, period_prefix):
    n = 0
    for entry in os.listdir(vault):
        log_path = os.path.join(vault, entry, "log.md")
        if not os.path.isfile(log_path):
            continue
        with open(log_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = SKIP_LINE_RX.match(line)
                if m and m.group(1) == period_prefix:
                    n += 1
    return n


def top_referenced(vault, limit=5):
    incoming = Counter()
    for dirpath, dirnames, filenames in os.walk(vault):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(".md") or fn in NOT_A_SOURCE:
                continue
            with open(os.path.join(dirpath, fn), encoding="utf-8",
                      errors="replace") as f:
                for target in WIKI_RX.findall(strip_code(f.read())):
                    base = os.path.basename(target.strip())
                    if base:
                        incoming[base] += 1
    return incoming.most_common(limit)


def main():
    try:
        cfg = load()
    except ConfigError as exc:
        sys.exit(f"A5N config error:\n{exc}")
    vault = cfg["vault"]["path"]
    s = STRINGS[lang_of(cfg)]
    start, nxt = period_of(sys.argv)
    period = start.strftime("%Y-%m")
    last_day = nxt - datetime.timedelta(days=1)
    today = datetime.date.today().isoformat()

    subjects = git_lines(vault, [
        "log", f"--since={start} 00:00:00", f"--until={nxt} 00:00:00",
        "--pretty=%s"])
    per_project = Counter()
    for subj in subjects:
        m = INGEST_RX.match(subj)
        if m:
            per_project[m.group(1)] += 1
    sessions = sum(per_project.values())

    created = changed_pages(vault, start, nxt, "A")
    modified = changed_pages(vault, start, nxt, "M") - created
    new_patterns = sorted(p for p in created if p.startswith("patterns/"))

    lines = [
        "---",
        f"title: {s['title'].format(vault=cfg['vault']['title'], period=period)}",
        "tags: [digest]",
        "source: manual",
        f"date: {last_day.isoformat()}",
        "status: active",
        "---",
        s["h1"].format(period=period, today=today),
        "",
        s["sessions"].format(n=sessions),
    ]
    lines += [f"- {proj}: {n}" for proj, n in per_project.most_common()] \
        or [s["none"]]

    cats = category_counts(created)
    cat_txt = ", ".join(f"{c} {n}" for c, n in cats.most_common())
    lines += ["", s["pages"],
              f"- {s['created'].format(n=len(created))}"
              + (f" ({cat_txt})" if cat_txt else ""),
              f"- {s['updated'].format(n=len(modified))}"]

    lines += ["", s["patterns"].format(n=len(new_patterns))]
    lines += [f"- [[{p[:-3]}]]" for p in new_patterns] or [s["none"]]

    top = top_referenced(vault)
    lines += ["", s["top"]]
    lines += [f"- [[{base[: -3] if base.endswith('.md') else base}]] "
              f"({s['links'].format(n=n)})" for base, n in top] or [s["none"]]

    lines += ["", s["skips"].format(n=skip_count(vault, period)), "",
              s["health"],
              s["quiet"] if sessions == 0 else s["ok"], ""]

    out_dir = os.path.join(vault, "digests")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{period}.md")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(os.path.relpath(out_path, vault))
    return 0


if __name__ == "__main__":
    sys.exit(main())
