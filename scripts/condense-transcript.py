#!/usr/bin/env python3
"""Reduce an agent transcript to a readable conversation skeleton.

Why this exists: transcript size comes from screen captures, not from content.
One session measured 107 MB, of which 2085 of 3733 lines were image
attachments; the conversation itself was 404 KB. The raw file did not fit in a
context window, so the daily ingest had been skipping that session in silence.

What it does: drops images entirely, truncates tool output, and keeps who said
what plus which tool was called with what. Statistics go to stderr, including
size, line types and the most used tools.

Both Claude Code and Codex transcripts are handled; the format is detected per
line.

Usage:
    python3 scripts/condense-transcript.py <input.jsonl> <output.txt> [limit]
    python3 scripts/condense-transcript.py --raw-copy <input.jsonl> <target.jsonl>

`limit` is how many characters to keep per tool output or thought, default 600.
Write the output under /tmp: never leave scratch files in the vault.

`--raw-copy` is a plain byte copy, kept here because this script is already
allowed to read the transcript directories and a shell `cp` of those paths can
hit sandbox restrictions.
"""
import collections
import json
import os
import re
import shutil
import sys

# An embedded image (Codex `input_image.image_url`) can be megabytes on a
# single line. It has to go BEFORE truncation: otherwise
# `json.dumps(...)[:limit]` spends the whole budget on base64 and the line
# carries no information at all.
B64_IMAGE = re.compile(r"data:image/[a-zA-Z.+-]+;base64,[A-Za-z0-9+/=\\\s]{40,}")


def strip_images(s):
    return B64_IMAGE.sub(lambda m: f"[image ~{len(m.group(0)) // 1024}K dropped]", s)


def text_of(content, tools, limit):
    """message.content, a string or a list of blocks, to plain text."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "text":
            parts.append(b.get("text", ""))
        elif t == "thinking":
            parts.append("[thinking] " + b.get("thinking", "")[:limit])
        elif t == "tool_use":
            name = b.get("name", "?")
            tools[name] += 1
            inp = json.dumps(b.get("input", {}), ensure_ascii=False)
            parts.append(f"[TOOL {name}] {inp[:limit]}")
        elif t == "tool_result":
            c = b.get("content")
            s = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
            # Keep the real length so the reader knows what was cut.
            parts.append(f"[RESULT {len(s)}chars] {s[:limit]}")
    return "\n".join(p for p in parts if p)


CODEX_TYPES = {"session_meta", "response_item", "event_msg", "turn_context"}


def is_codex(d):
    return d.get("type") in CODEX_TYPES and isinstance(d.get("payload"), dict)


def codex_line(d, tools, limit):
    """A Codex line to (role, body). An empty body means the line is skipped.

    The Codex shape differs from the Claude one: content sits in `payload`
    rather than `message`, and conversation text can appear twice, once as
    `event_msg/{user,agent}_message` and once as `response_item/message`. The
    `response_item` side wins here and the event copies are skipped.
    """
    p = d.get("payload") or {}
    t = d.get("type")
    pt = p.get("type")

    if t == "session_meta":
        return "session_meta", (f"cwd={p.get('cwd')} originator={p.get('originator')} "
                                f"cli={p.get('cli_version')} id={p.get('id')}")
    if t == "turn_context":
        return "", ""          # metadata only, no body
    if t == "compacted":
        return "compaction", "[COMPACTION SUMMARY] " + strip_images(
            json.dumps(p, ensure_ascii=False))[:2000]

    if t == "event_msg":
        if pt == "mcp_tool_call_end":
            inv = p.get("invocation") or {}
            name = f"{inv.get('server', '?')}.{inv.get('tool', '?')}"
            tools[name] += 1
            args = json.dumps(inv.get("arguments", {}), ensure_ascii=False)
            return "mcp", f"[MCP {name}] {args[:limit]}"
        if pt == "patch_apply_end":
            out = (p.get("stdout") or "") + (p.get("stderr") or "")
            return "patch", f"[PATCH {'ok' if p.get('success') else 'HATA'}] {out[:limit]}"
        if pt == "task_complete":
            # the closing message of a turn, which is the best summary of what
            # actually happened
            return "task_complete", str(p.get("last_agent_message") or "")
        # user_message and agent_message duplicate response_item/message
        return "", ""

    if t == "response_item":
        if pt == "message":
            role = p.get("role", "?")
            parts = []
            for b in p.get("content") or []:
                if isinstance(b, dict) and b.get("text"):
                    parts.append(b["text"])
            body = "\n".join(parts)
            # the developer role carries the static system prompt, repeated on every turn
            if role == "developer":
                body = body[:limit]
            return role, body
        if pt in ("function_call", "custom_tool_call"):
            # custom_tool_call is apply_patch, a code edit. Its payload carries
            # `input` rather than `arguments`, and the patch body is in there.
            name = p.get("name", "?")
            tools[name] += 1
            arg = p.get("arguments") if pt == "function_call" else p.get("input")
            return "tool", f"[TOOL {name}] {str(arg or '')[:limit]}"
        if pt in ("function_call_output", "custom_tool_call_output"):
            s = p.get("output")
            s = s if isinstance(s, str) else json.dumps(s, ensure_ascii=False)
            raw_len = len(s)
            s = strip_images(s)
            return "tool_result", f"[RESULT {raw_len}chars] {s[:limit]}"
        if pt == "reasoning":
            # encrypted_content is an opaque blob nobody can read, so only the
            # summary is worth keeping
            summary = p.get("summary") or []
            txt = " ".join(str(x) for x in summary)[:limit]
            return ("reasoning", f"[thinking] {txt}") if txt else ("", "")
        if pt in ("tool_search_call", "tool_search_output"):
            return "", ""
    return "", ""


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)

    if sys.argv[1] == "--raw-copy":
        if len(sys.argv) < 4:
            sys.exit(__doc__)
        src, dest = sys.argv[2], sys.argv[3]
        if os.path.exists(dest):
            sys.exit(f"target already exists, not overwritten: {dest}")
        shutil.copyfile(src, dest)
        sys.stderr.write(f"copied: {src} -> {dest} ({os.path.getsize(dest)} bytes)\n")
        return

    src, out = sys.argv[1], sys.argv[2]
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 600

    types = collections.Counter()
    tools = collections.Counter()
    first_ts = last_ts = cwd = branch = None
    lines = 0
    fmt = "claude"

    # Encoding is explicit on purpose: under launchd, LANG comes through empty
    # and trusting the platform default corrupts non ASCII text.
    with open(src, "r", encoding="utf-8", errors="replace") as f, \
            open(out, "w", encoding="utf-8") as o:
        for raw in f:
            lines += 1
            try:
                d = json.loads(raw)
            except ValueError:
                types["PARSE-ERROR"] += 1
                continue
            ts = d.get("timestamp")
            if ts:
                first_ts = first_ts or ts
                last_ts = ts
            branch = d.get("gitBranch") or branch

            if is_codex(d):
                fmt = "codex"
                p = d.get("payload") or {}
                types[f"{d.get('type')}/{p.get('type') or '-'}"] += 1
                cwd = p.get("cwd") or cwd
                role, body = codex_line(d, tools, limit)
            else:
                types[d.get("type", "?")] += 1
                cwd = d.get("cwd") or cwd
                msg = d.get("message") or {}
                body = text_of(msg.get("content", ""), tools, limit)
                if d.get("type") == "summary":
                    body = "[COMPACTION SUMMARY] " + str(d.get("summary", ""))[:2000]
                role = msg.get("role") or d.get("type")

            # lines with no body (attachments, telemetry) are not written
            if not body or not body.strip():
                continue
            o.write(f"\n===== #{lines} {role} {ts or ''} =====\n{body}\n")

    src_mb = os.path.getsize(src) / 1048576
    out_mb = os.path.getsize(out) / 1048576
    w = sys.stderr.write
    w(f"[{fmt}] {src_mb:.1f}MB -> {out_mb:.2f}MB ({lines} lines)\n")
    w(f"first: {first_ts}\nlast: {last_ts}\ncwd: {cwd}\nbranch: {branch}\n")
    w(f"line types: {dict(types)}\n")
    w(f"tools: {dict(tools.most_common(12))}\n")


if __name__ == "__main__":
    main()
