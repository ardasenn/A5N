#!/usr/bin/env python3
"""Tests for personal data masking and the MCP server's profiles.

What this guards: a session full of other people's contact details must not
reach git or an MCP client in clear (scripts/privacy.py), and a client
started with --profile must not see the pages the profile hides, nor the
lines of other pages that name them (scripts/a5n-mcp.py).

Everything happens in a temporary directory: a scratch config.ini (passed
through A5N_CONFIG) and a scratch vault that is its own git repository. No
real vault is touched, no model runs. Every value below is invented; the id
and tax numbers are generated to pass their checksums. Runs on macOS and
Linux, needs only python3 and git.

Usage: python3 tests/privacy.py
       A5N_KEEP_TEST_DIR=1 python3 tests/privacy.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))
import privacy  # noqa: E402

PRIVACY = os.path.join(REPO, "scripts", "privacy.py")
MCP = os.path.join(REPO, "scripts", "a5n-mcp.py")
DOT = "•"
FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)
        if detail:
            print("     " + detail.replace("\n", "\n     "))


def tckn_from(nine):
    d = [int(c) for c in nine]
    d10 = (sum(d[0:9:2]) * 7 - sum(d[1:8:2])) % 10
    d11 = (sum(d) + d10) % 10
    return nine + str(d10) + str(d11)


def vkn_from(nine):
    for last in "0123456789":
        if privacy.vkn_valid(nine + last):
            return nine + last
    raise AssertionError("no check digit")


POL = {
    "enabled": True,
    "keep_emails": {"me@mycompany.example.org"},
    "keep_domains": {"demo-school.dev"},
    "keep_phones": {"5550001122"},
}


def unit_tests():
    m = lambda t: privacy.mask(t, POL)[0]  # noqa: E731

    check("person e-mail keeps first letter and domain",
          m("mail: jane.roe@acme-corp.com.tr") == f"mail: j{DOT*3}@acme-corp.com.tr")
    check("role, test, kept and service addresses stay",
          m("support@acme.io admin1@acme.io ci-runner@x.test "
            "a@example.com me@mycompany.example.org t@demo-school.dev "
            "bot@p.iam.gserviceaccount.com")
          == "support@acme.io admin1@acme.io ci-runner@x.test "
             "a@example.com me@mycompany.example.org t@demo-school.dev "
             "bot@p.iam.gserviceaccount.com")
    check("unit files and packages are not mail",
          m("postgresql@17-main.service logo@2x.png") ==
          "postgresql@17-main.service logo@2x.png")
    check("prefixed mobile keeps prefix and last two digits",
          m("tel +905321234567 ve 0 (532) 123 45 67")
          == f"tel +90{DOT*8}67 ve 0 ({DOT*3}) {DOT*3} {DOT*2} 67")
    check("grouped mobile without prefix",
          m("ara 532 123 45 67") == f"ara {DOT*3} {DOT*3} {DOT*2} 67")
    check("bare ten digits only on a phone line",
          m("ilan 5321234567") == "ilan 5321234567"
          and m("telefon 5321234567") == f"telefon {DOT*8}67")
    check("kept phone stays in any spelling",
          m("bot +90 555 000 11 22 / 05550001122")
          == "bot +90 555 000 11 22 / 05550001122")
    tc = tckn_from("123456789")
    bad = tc[:-1] + str((int(tc[-1]) + 1) % 10)
    check("valid national id masked, invalid left",
          m(f"id {tc} / {bad}") == f"id {DOT*9}{tc[-2:]} / {bad}")
    vkn = vkn_from("123456789")
    check("tax number only next to a tax word",
          m(f"vergi_no {vkn}") == f"vergi_no {DOT*8}{vkn[-2:]}"
          and m(f"listing {vkn}") == f"listing {vkn}")
    once = m(f"x jane@acme.com +905321234567 {tc}")
    check("masking twice changes nothing", m(once) == once)
    check("no asterisks in masks", "*" not in once)
    check("mask reports counts per kind",
          privacy.mask("jane@acme.com", POL)[1] == {"email": 1})


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True,
                          text=True, check=True).stdout


def page(title, tags, body):
    return (f"---\ntitle: {title}\ntags: [{', '.join(tags)}]\n"
            f"source: manual\ndate: 2026-10-01\nstatus: active\n---\n\n"
            f"# {title}\n\n{body}\n")


def mcp_call(env, args, calls):
    msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}]
    for i, (name, arguments) in enumerate(calls, 1):
        msgs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                     "params": {"name": name, "arguments": arguments}})
    proc = subprocess.run(
        [sys.executable, MCP, *args], env=env, capture_output=True, text=True,
        input="\n".join(json.dumps(m) for m in msgs) + "\n")
    out = [json.loads(line) for line in proc.stdout.splitlines() if line]
    texts = [r["result"]["content"][0]["text"] for r in out[1:]]
    return proc.returncode, texts, proc.stderr


def end_to_end(tmp):
    vault = os.path.join(tmp, "vault")
    cfg = os.path.join(tmp, "config.ini")
    write(cfg, f"""[vault]
path = {vault}

[privacy]
mask = yes
keep_emails = me@mycompany.example.org

[mcp:assistant]
hide_tags = security

[project:shop]
match = shop
watermark = 2026-01-01
""")
    env = dict(os.environ, A5N_CONFIG=cfg)

    write(os.path.join(vault, "index.md"), "# Index\n")
    write(os.path.join(vault, "shop", "index.md"),
          "# shop\n\n- [[csrf-hole-in-checkout]]: checkout accepts forged posts\n"
          "- [[2026-10-01-checkout-session]]: the session\n")
    write(os.path.join(vault, "shop", "bugs", "csrf-hole-in-checkout.md"),
          page("CSRF hole in checkout", ["shop", "bug", "security"],
               "Forged posts pass the checkout handler."))
    write(os.path.join(vault, "shop", "sources", "sessions",
                       "2026-10-01-checkout-session.md"),
          page("Checkout session", ["shop", "session"],
               "Reported by jane.roe@acme-corp.com, phone +905321234567.\n"
               "Fixed the hole, see [[csrf-hole-in-checkout]].\n"
               "Unrelated line about the cart."))
    write(os.path.join(vault, "shop", "raw", "sessions", "x.md"),
          "jane.roe@acme-corp.com stays in raw")
    git(vault, "init", "-q")
    git(vault, "add", "-A")
    git(vault, "-c", "user.email=t@t.test", "-c", "user.name=t", "commit",
        "-qm", "base")

    # what the ingest driver does after a worker: only changed pages
    new_page = os.path.join(vault, "shop", "entities", "customer.md")
    write(new_page, page("Customer", ["shop"], "Mail jane.roe@acme-corp.com"))
    raw_new = os.path.join(vault, "shop", "raw", "sessions", "y.md")
    write(raw_new, "jane.roe@acme-corp.com in a new raw file")
    proc = subprocess.run([sys.executable, PRIVACY, "fix", "--changed"],
                          cwd=vault, env=env, capture_output=True, text=True)
    with open(new_page, encoding="utf-8") as f:
        masked = f.read()
    with open(raw_new, encoding="utf-8") as f:
        raw_after = f.read()
    with open(os.path.join(vault, "shop", "sources", "sessions",
                           "2026-10-01-checkout-session.md"),
              encoding="utf-8") as f:
        untouched = f.read()
    check("fix --changed masks the changed page",
          proc.returncode == 0 and f"j{DOT*3}@acme-corp.com" in masked,
          proc.stdout + proc.stderr)
    check("fix --changed leaves raw/ and unchanged pages alone",
          "jane.roe@" in raw_after and "jane.roe@" in untouched)
    check("its log names no value", "jane" not in proc.stdout)
    scan = subprocess.run([sys.executable, PRIVACY, "scan", vault],
                          env=env, capture_output=True, text=True)
    check("scan reports the committed page and exits 1",
          scan.returncode == 1 and "checkout-session" in scan.stdout
          and "jane" not in scan.stdout, scan.stdout)

    calls = [
        ("vault_page", {"path": "shop/sources/sessions/2026-10-01-checkout-session.md"}),
        ("vault_page", {"path": "shop/bugs/csrf-hole-in-checkout.md"}),
        ("vault_search", {"query": "forged checkout"}),
        ("vault_page", {"path": "shop/index.md"}),
        ("vault_overview", {}),
    ]
    rc, plain, err = mcp_call(env, [], calls)
    check("no profile: every page served, personal data masked",
          rc == 0 and "csrf-hole-in-checkout" in plain[0]
          and f"j{DOT*3}@acme-corp.com" in plain[0]
          and f"+90{DOT*8}67" in plain[0] and "jane" not in plain[0]
          and "Forged posts" in plain[1], err)

    rc, prof, err = mcp_call(env, ["--profile", "assistant"], calls)
    check("profile: a line naming a hidden page is dropped, the rest stays",
          "csrf-hole-in-checkout" not in prof[0]
          and "Unrelated line about the cart." in prof[0], prof[0])
    check("profile: the hidden page itself is refused",
          prof[1].startswith("not available to this client"), prof[1])
    check("profile: search does not surface it",
          "csrf-hole" not in prof[2] and "Forged" not in prof[2], prof[2])
    check("profile: index entry for it is gone",
          "forged posts" not in prof[3] and "checkout-session" in prof[3],
          prof[3])
    check("profile: overview counts leave it out",
          "bugs" not in prof[4].split("Cross project")[0], prof[4])

    rc, _, err = mcp_call(env, ["--profile", "nosuch"], calls[:1])
    check("an unknown profile stops the server instead of serving all",
          rc == 1 and "no [mcp:nosuch] section" in err, err)


def main():
    unit_tests()
    tmp = tempfile.mkdtemp(prefix="a5n-privacy-")
    try:
        end_to_end(tmp)
    finally:
        if os.environ.get("A5N_KEEP_TEST_DIR"):
            print(f"kept {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    if FAILS:
        print(f"\n{len(FAILS)} failed")
        return 1
    print("\nall passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
