#!/usr/bin/env python3
"""Print transcript metadata, used by the ingest to route candidates.

ingest-discover.py imports `meta()` from here to decide which project a Codex
session belongs to (by its cwd) and what filename it gets in the vault. The
command line form exists for inspecting transcripts by hand.

Usage:
    python3 scripts/transcript-meta.py <transcript.jsonl> [...]

One tab separated line per file:
    <format>\t<session_id>\t<cwd>\t<target_filename>\t<path>

format      claude or codex
session_id  payload.id or payload.session_id in Codex, sessionId in Claude
cwd         from the Codex session_meta record, or the first cwd field
target      the filename to use inside the vault, codex- prefixed for Codex

An unreadable file produces an `error` line and the exit code stays 0, so one
bad file never takes down the rest of the queue.
"""
import json
import os
import sys

CODEX_TYPES = {"session_meta", "response_item", "event_msg", "turn_context"}


def meta(path, scan_lines=40):
    fmt = "claude"
    sid = cwd = ""
    with open(path, errors="replace") as f:
        for i, line in enumerate(f):
            if i >= scan_lines:
                break
            try:
                d = json.loads(line)
            except Exception:
                continue
            if not isinstance(d, dict):
                continue
            p = d.get("payload")
            if d.get("type") in CODEX_TYPES and isinstance(p, dict):
                fmt = "codex"
                sid = sid or p.get("id") or p.get("session_id") or ""
                cwd = cwd or p.get("cwd") or ""
            else:
                sid = sid or d.get("sessionId") or ""
                cwd = cwd or d.get("cwd") or ""
            if sid and cwd:
                break
    if not sid:
        sid = os.path.splitext(os.path.basename(path))[0]
    target = f"codex-{sid}.jsonl" if fmt == "codex" else f"{sid}.jsonl"
    return fmt, sid, cwd, target


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        try:
            fmt, sid, cwd, target = meta(path)
        except OSError as e:
            print(f"error\t\t\t\t{path} ({e})")
            continue
        print(f"{fmt}\t{sid}\t{cwd}\t{target}\t{path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
