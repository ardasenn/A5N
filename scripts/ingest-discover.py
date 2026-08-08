#!/usr/bin/env python3
"""Ingest layer 1: deterministic discovery, capture and queue. No LLM here.

Design principle: orchestration lives in scripts, the model is only called
for the one job it is good at, "read this transcript, write the pages". An
earlier design handed discovery, dedup, copying and waiting to a single
headless agent run, and every week produced a new choreography failure: a
background wait ceiling cut runs short, a backticked signature line voided a
finished day, a turn ending killed work in flight. None of those failure
modes can exist in a Python script.

State is not kept in a separate file, THE VAULT ITSELF IS THE STATE:
    captured  = <project>/raw/sessions/<id>.jsonl exists
    processed = a TRACE exists, and a trace is exactly one of two things:
                  * a sources/sessions page containing the full raw path
                    "raw/sessions/<id>.jsonl" (its source: field, or a
                    ## Sources entry on a continuation page)
                  * a "skip | <id>" line in <project>/log.md

A raw file whose id has no trace is by definition still queued, so a failed
unit retries tomorrow with no bookkeeping at all.

The trace definition is deliberately this narrow. The first version used
"the id appears in any .md in the namespace", and that substring test
produced the same bug twice in one day: first the dedup skip line quoted
the KEPT file's full name and dequeued it, then the superset note carried
the CANDIDATE's own id and dequeued that. A bare id mentioned in prose is
not a trace and can never dequeue anything again; only the two shapes
above count, and ingest-verify.py accepts exactly the same two shapes.

Usage:
    python3 scripts/ingest-discover.py capture [--dry-run]
    python3 scripts/ingest-discover.py queue

capture scans both transcript sources from config.ini:
  * Claude Code: folders under agents.claude_projects whose name contains a
    project's match value; every *.jsonl at the folder root is a candidate.
    Files under subfolders (subagents/, tool-results/) are not sessions.
  * Codex: rollout-*.jsonl anywhere under agents.codex_sessions. The folder
    name says nothing there, so the project is decided by the session's own
    working directory, read through transcript-meta.

Filter order: watermark, freshness (the session may still be running),
already in the vault, too small, duplicate content. Survivors are copied
through the import-transcript filter into raw/. Small and duplicate drops get
a deterministic skip line in <project>/log.md: "never skip in silence" is now
a script guarantee, not a prompt request. Watermark and freshness drops write
no line, the first is deliberate, the second resolves itself tomorrow.

Duplicate detection is by CONTENT, not filename: if a candidate's first
surviving line equals an existing raw's first line they are the same
conversation. Candidate contained in existing: redundant, skip line.
Candidate larger: copied under its new id, the old file is NOT deleted
(hard rule 1, pruning redundant raws is the user's call), noted in the log.

queue prints unprocessed raws as TSV (project, id, raw path, bytes, date),
oldest session first, capped by limits.max_units (env A5N_MAX_UNITS
overrides). Totals go to stderr.

Known accepted blind spot: a session skipped as "too small" whose transcript
later grows will not become a candidate again, its id is already in the
namespace. The freshness window makes this rare in practice.
"""
import datetime
import importlib.util
import os
import re
import subprocess
import sys

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPTS_DIR)
from config import load, ConfigError  # noqa: E402


def _import(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(SCRIPTS_DIR, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Single owners of their logic, imported rather than copied here:
# the transcript filter and the format/cwd/target metadata reader.
_it = _import("import_transcript", "import-transcript.py")
_tm = _import("transcript_meta", "transcript-meta.py")

TS_RX = re.compile(r'"timestamp"\s*:\s*"(\d{4}-\d{2}-\d{2})')


def filtered_lines(path):
    """Lines that survive the import filter, format detected per file."""
    drop = (_it.should_drop_codex if _it.detect_format(path) == "codex"
            else _it.should_drop_claude)
    with open(path, errors="replace") as f:
        for line in f:
            if not drop(line):
                yield line


def first_kept_line(path):
    return next(filtered_lines(path), None)


def relation(candidate, existing):
    """Lockstep comparison of the filtered candidate against an existing raw.

    'subset'    = candidate is contained in existing (equality included),
                  redundant, not copied
    'superset'  = candidate carries more, copied
    'divergent' = same first line but the content forks, keep both
    """
    cg = filtered_lines(candidate)
    with open(existing, errors="replace") as ef:
        for eline in ef:
            cline = next(cg, None)
            if cline is None:
                return "subset"
            if cline != eline:
                return "divergent"
    return "superset" if next(cg, None) is not None else "subset"


def session_date(path):
    """The transcript's own date (first timestamp), falling back to mtime."""
    with open(path, errors="replace") as f:
        for i, line in enumerate(f):
            m = TS_RX.search(line)
            if m:
                return m.group(1)
            if i > 200:
                break
    return datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()


def match_one(projects, text, what):
    """Match a folder name or cwd to a project. Two matches is a config bug
    that must stop the run, or one project's sessions leak into another."""
    low = text.lower()
    hits = [p for p in projects if p["match"].lower() in low]
    if len(hits) > 1:
        sys.exit(f"error: {what} '{text}' matches more than one project: "
                 f"{[p['name'] for p in hits]}. Make the match values in "
                 f"config.ini distinct.")
    return hits[0] if hits else None


def iter_candidates(cfg):
    """Yield (project, source_path, id, target_filename) across both formats."""
    projects = cfg["_projects"]

    root = cfg["agents"]["claude_projects"]
    if root and os.path.isdir(root):
        for d in sorted(os.listdir(root)):
            pdir = os.path.join(root, d)
            if not os.path.isdir(pdir):
                continue
            proj = match_one(projects, d, "Claude project folder")
            if not proj:
                continue
            # folder root only: subagents/ and tool-results/ are not sessions
            for f in sorted(os.listdir(pdir)):
                if f.endswith(".jsonl"):
                    sid = os.path.splitext(f)[0]
                    yield proj, os.path.join(pdir, f), sid, f

    root = cfg["agents"]["codex_sessions"]
    if root and os.path.isdir(root):
        for dirpath, _dirnames, filenames in os.walk(root):
            for f in sorted(filenames):
                if not (f.startswith("rollout-") and f.endswith(".jsonl")):
                    continue
                src = os.path.join(dirpath, f)
                try:
                    _fmt, sid, cwd, target = _tm.meta(src)
                except OSError:
                    continue
                if not cwd:
                    continue
                proj = match_one(projects, cwd, "Codex session cwd")
                if proj:
                    yield proj, src, os.path.splitext(target)[0], target


def trace_text(vault, proj):
    """(sources_text, log_text): the only two places a trace may live."""
    chunks = []
    sdir = os.path.join(vault, proj, "sources", "sessions")
    if os.path.isdir(sdir):
        for fn in sorted(os.listdir(sdir)):
            if fn.endswith(".md"):
                with open(os.path.join(sdir, fn), errors="replace") as f:
                    chunks.append(f.read())
    log_text = ""
    log_path = os.path.join(vault, proj, "log.md")
    if os.path.isfile(log_path):
        with open(log_path, errors="replace") as f:
            log_text = f.read()
    return "\n".join(chunks), log_text


def is_processed(traces, sid):
    sources_text, log_text = traces
    if f"raw/sessions/{sid}.jsonl" in sources_text:
        return True
    return re.search(rf"skip \| {re.escape(sid)}\b", log_text) is not None


def append_skip(vault, proj, line, dry):
    if dry:
        print(f"  [dry-run] {proj}/log.md <- {line}")
        return
    today = datetime.date.today().isoformat()
    with open(os.path.join(vault, proj, "log.md"), "a", encoding="utf-8") as f:
        f.write(f"\n## [{today}] {line}\n")


def capture(cfg, dry):
    vault = cfg["vault"]["path"]
    now = datetime.datetime.now().timestamp()
    fresh_sec = float(cfg["limits"]["settle_hours"]) * 3600
    min_bytes = int(cfg["limits"]["min_session_kb"]) * 1024
    counts = {"copied": 0, "watermark": 0, "fresh": 0, "present": 0,
              "small": 0, "redundant": 0, "larger": 0, "divergent": 0}

    # project -> {first line: [raw path, ...]}, built lazily
    fl_index, trace_cache = {}, {}

    def index_of(proj):
        if proj not in fl_index:
            idx = {}
            rdir = os.path.join(vault, proj, "raw", "sessions")
            if os.path.isdir(rdir):
                for fn in os.listdir(rdir):
                    if fn.endswith(".jsonl"):
                        p = os.path.join(rdir, fn)
                        fl = first_kept_line(p)
                        if fl is not None:
                            idx.setdefault(fl, []).append(p)
            fl_index[proj] = idx
        return fl_index[proj]

    def traces_of(proj):
        if proj not in trace_cache:
            trace_cache[proj] = trace_text(vault, proj)
        return trace_cache[proj]

    for proj, src, sid, target in iter_candidates(cfg):
        name = proj["name"]
        st = os.stat(src)

        # The watermark compares the session's own date, not the file's
        # mtime: a copy or a sync refreshes mtime, and a June session must
        # not slip past a July watermark for having a young file.
        sdate = session_date(src)
        if proj["watermark"] and sdate < proj["watermark"]:
            counts["watermark"] += 1
            continue
        if now - st.st_mtime < fresh_sec:
            counts["fresh"] += 1
            print(f"fresh, may still be running, tomorrow: {name}/{sid}")
            continue

        dst = os.path.join(vault, name, "raw", "sessions", target)
        if os.path.exists(dst) or is_processed(traces_of(name), sid):
            counts["present"] += 1
            continue
        if st.st_size < min_bytes:
            counts["small"] += 1
            append_skip(vault, name,
                        f"skip | {sid} (small session, {st.st_size // 1024}KB, "
                        f"raw not copied)", dry)
            trace_cache.pop(name, None)
            continue

        fl = first_kept_line(src)
        dup_note = None
        if fl is not None and fl in index_of(name):
            rels = [(relation(src, ex), ex) for ex in index_of(name)[fl]]
            # Ids inside these log lines are truncated to 8 chars, with ONE
            # exception: the subset skip line carries the candidate's full
            # id, because that line IS the processed trace that removes the
            # (never copied) candidate from the queue. Everywhere else a
            # full id would be poison: "id appears in the namespace" is the
            # processed test, so a full id in a mere note silently drops
            # that session from the queue before any page exists. Both
            # directions of this bug shipped once, caught by smoke tests
            # on 2026-08-07: first the kept file's name in the skip line,
            # then the candidate's own id in the superset note.
            other = os.path.basename(rels[0][1])[:8] + "…"
            if any(r == "subset" for r, _ in rels):
                counts["redundant"] += 1
                append_skip(vault, name,
                            f"skip | {sid} contained in {other}, raw not copied",
                            dry)
                trace_cache.pop(name, None)
                continue
            if any(r == "superset" for r, _ in rels):
                counts["larger"] += 1
                dup_note = (f"note | {sid[:8]}… is a LARGER copy of the "
                            f"same conversation ({other} kept, pruning is "
                            f"the user's call)")
            else:
                counts["divergent"] += 1
                dup_note = (f"note | {sid[:8]}… shares its first line with "
                            f"{other} but the content forks, both kept, "
                            f"check them")

        if dry:
            print(f"[dry-run] would copy: {name}/{sid} "
                  f"({st.st_size // 1024}KB, {sdate})")
            counts["copied"] += 1
            # feed the index in dry runs too, or a duplicate WITHIN the
            # candidate set goes uncounted and setup's "N sessions are
            # waiting" overstates the model runs it is asking to approve
            if fl is not None:
                index_of(name).setdefault(fl, []).append(src)
            continue
        r = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS_DIR, "import-transcript.py"),
             src, dst], capture_output=True, text=True)
        print(r.stdout.strip())
        if r.returncode != 0:
            # A capture failure is a data risk, the source deletion clock is
            # ticking. Stop loudly, the driver notifies.
            sys.exit(f"error: import failed ({name}/{sid}): {r.stderr.strip()}")
        if dup_note:
            append_skip(vault, name, dup_note, dry)
        counts["copied"] += 1
        if fl is not None:
            index_of(name).setdefault(fl, []).append(dst)

    print("capture summary: " + ", ".join(f"{k}={v}" for k, v in counts.items()))


def queue(cfg):
    vault = cfg["vault"]["path"]
    units = []
    for proj in cfg["_projects"]:
        name = proj["name"]
        rdir = os.path.join(vault, name, "raw", "sessions")
        if not os.path.isdir(rdir):
            continue
        traces = trace_text(vault, name)
        for fn in sorted(os.listdir(rdir)):
            if not fn.endswith(".jsonl"):
                continue
            sid = os.path.splitext(fn)[0]
            if is_processed(traces, sid):
                continue
            p = os.path.join(rdir, fn)
            units.append((session_date(p), name, sid, p, os.path.getsize(p)))
    units.sort()
    cap = int(os.environ.get("A5N_MAX_UNITS") or cfg["limits"]["max_units"])
    for d, name, sid, p, size in units[:cap]:
        print(f"{name}\t{sid}\t{os.path.relpath(p, vault)}\t{size}\t{d}")
    msg = f"queue: {len(units)} unprocessed units"
    if len(units) > cap:
        msg += f", {cap} in this run (cap), the rest tomorrow"
    print(msg, file=sys.stderr)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("capture", "queue"):
        sys.exit(__doc__)
    try:
        cfg = load()
    except ConfigError as exc:
        sys.exit(f"A5N config error:\n{exc}")
    os.chdir(cfg["vault"]["path"])
    if sys.argv[1] == "capture":
        capture(cfg, dry="--dry-run" in sys.argv)
    else:
        queue(cfg)


if __name__ == "__main__":
    main()
