#!/usr/bin/env python3
"""Copy an agent transcript into the vault, filtered (INGEST step 0).

Two formats are recognised from the first line:
  - Claude Code, <claude_projects>/<folder>/<uuid>.jsonl
  - Codex,       <codex_sessions>/YYYY/MM/DD/rollout-*.jsonl

Why filter at all: in Claude Code, roughly 64% of a transcript is
`attachment/hook_success` records that carry nothing new. A continuous
learning hook writes its own payload back to stdout, so every tool result is
stored a second time. One measurement across the fifteen largest sessions,
509 MB in total:

    attachment/hook_success   327.8 MB   64.4%   <- dropped
    tool_result               155.1 MB   30.5%   <- kept
    thinking + tool_use        13.7 MB    2.7%   <- kept
    images                      3.8 MB    0.8%   <- kept
    the conversation itself     2.0 MB    0.4%   <- kept

Dropped lines are copies, so nothing is lost: the same data is still in the
file as `tool_result` and `tool_use`.

Codex has no hook echo, so there only `event_msg/token_count` telemetry is
dropped, which is about 1.4%. The saving is small and that is fine: the point
of this step is permanence, not compression. Agents delete old transcripts
after a while and the vault keeps its own copy.

Usage:
    python3 scripts/import-transcript.py <source.jsonl> <target.jsonl>

Exit code 0 means copied. An existing target is left untouched and still
returns 0, so the step is idempotent. One summary line on stdout.
"""
import json
import os
import sys

DROP_ATTACHMENT_TYPES = {"hook_success"}


def detect_format(path):
    """Return 'codex' or 'claude', decided from the first parseable line.

    The Codex signature is a top level `payload` dict alongside a `type` of
    session_meta, response_item, event_msg or turn_context.
    """
    codex_types = {"session_meta", "response_item", "event_msg", "turn_context"}
    with open(path, errors="replace") as f:
        for _ in range(5):
            line = f.readline()
            if not line:
                break
            try:
                d = json.loads(line)
            except Exception:
                continue
            if not isinstance(d, dict):
                continue
            if d.get("type") in codex_types and isinstance(d.get("payload"), dict):
                return "codex"
            return "claude"
    return "claude"  # when in doubt, the default that drops the least


def should_drop_claude(line):
    """True means the line is not written. When in doubt, keep it."""
    if '"hook_success"' not in line:
        return False  # fast reject: not a candidate
    try:
        d = json.loads(line)
    except Exception:
        return False  # unparseable, so leave it alone
    if d.get("type") != "attachment":
        return False
    att = d.get("attachment")
    if not isinstance(att, dict):
        return False
    return att.get("type") in DROP_ATTACHMENT_TYPES


def should_drop_codex(line):
    """Only pure telemetry lines (`event_msg/token_count`) are dropped."""
    if '"token_count"' not in line:
        return False
    try:
        d = json.loads(line)
    except Exception:
        return False
    if d.get("type") != "event_msg":
        return False
    p = d.get("payload")
    return isinstance(p, dict) and p.get("type") == "token_count"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]

    if not os.path.isfile(src):
        sys.exit(f"error: source not found: {src}")
    if os.path.exists(dst):
        print(f"skipped, target already exists: {dst}")
        return 0

    src_size = os.path.getsize(src)
    dropped = kept = dropped_bytes = 0

    fmt = detect_format(src)
    should_drop = should_drop_codex if fmt == "codex" else should_drop_claude

    tmp = dst + ".partial"
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    try:
        with open(src, errors="replace") as fin, open(tmp, "w") as fout:
            for line in fin:
                if should_drop(line):
                    dropped += 1
                    dropped_bytes += len(line)
                    continue
                fout.write(line)
                kept += 1
        os.replace(tmp, dst)
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise

    dst_size = os.path.getsize(dst)
    mb = 1048576.0
    pct = 100.0 * dropped_bytes / src_size if src_size else 0.0
    label = "telemetry" if fmt == "codex" else "hook"
    print(f"{os.path.basename(dst)}: [{fmt}] {src_size/mb:.1f} MB -> {dst_size/mb:.1f} MB "
          f"({pct:.1f}% filtered, {dropped} {label} records dropped, {kept} lines kept)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
