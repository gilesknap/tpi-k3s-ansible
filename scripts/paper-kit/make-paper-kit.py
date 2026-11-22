#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["reportlab"]
# ///
"""Paper disaster-recovery kit for the home cluster.

Run:  scripts/paper-kit/run.sh            (browser form; see --gui below)
      scripts/paper-kit/run.sh --cli      (terminal prompts, writes the PDF)
      uv run scripts/paper-kit/make-paper-kit.py [--cli] [out.pdf]
See docs/how-to/paper-kit.md.

The kit's data is not in git, not even encrypted: it lives in the data
directory, _claude/paper-kit-data/ at the repo root (gitignored), or
$PAPER_KIT_DATA if set:
  cluster-creds.age  age armor: every cluster credential (refresh-embedded.sh)
  answers.age        age armor: the saved answers to the form (this script)
  kit.json           optional, plain JSON, nothing secret: private facts the
                     PDF prints, e.g. {"extra_drive_folders":
                     [{"name": "<Drive folder>", "what": "<what it holds>"}]}
refresh-embedded.sh creates the directory; this script stops with an error
if it is missing.

Terminal mode (--cli, or no mode flag):
1. Asks for the cluster's age private key and refuses any key whose public
   key is not RECIPIENT.
2. Decrypts the two files in the data directory (cluster-creds.age, written
   by refresh-embedded.sh; answers.age, written by this script).
3. Asks for anything it doesn't know (Enter keeps a saved answer).
4. Offers to save the answers, encrypted to RECIPIENT, back into answers.age.
5. Writes the PDF (mode 0600). Print it, then delete it.

Secrets never touch the disk in plaintext except in the PDF you asked for:
the key reaches age through a pipe (/dev/fd/N), never a file or argv.

Browser mode (--gui): serves the same flow as a form on 127.0.0.1 only, at a
URL with a one-time token (printed as the only line on stdout). The key and the
answers stay in this process's memory; the PDF is built in memory and handed to
the browser as a download. Finish (or 30 minutes idle) stops the server.

Other modes:
  make-paper-kit.py --splice-creds    read armored age ciphertext on stdin
                                      and store it as cluster-creds.age
                                      (used by refresh-embedded.sh)

Test-only environment (never set these for a real run):
  PAPER_KIT_TEST_RECIPIENT  use this public key in place of RECIPIENT
  PAPER_KIT_TEST_STDIN=1    with the above, read secret prompts from stdin
                            (plain readline) instead of getpass
  PAPER_KIT_TEST_IDLE=N     with the above, --gui idle timeout in seconds
"""

from __future__ import annotations

import datetime as dt
import getpass
import io
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

RECIPIENT = "age13c5tkz4n35adg7vy73c4lk2tj5av2t8sgwy8u60uwx3ue5n5j95sly0x20"

SCRIPT = Path(__file__).resolve()
REPO = SCRIPT.parents[2]  # <repo>/scripts/paper-kit/make-paper-kit.py
# The kit's private data (see the docstring); never in git.
DATA = Path(os.environ.get("PAPER_KIT_DATA") or REPO / "_claude" / "paper-kit-data")
BLOCK_FILES = {"CLUSTER-CREDS": "cluster-creds.age", "ANSWERS": "answers.age"}
KIT_CONFIG = "kit.json"

TEST_RECIPIENT = os.environ.get("PAPER_KIT_TEST_RECIPIENT", "")
TEST_STDIN = bool(TEST_RECIPIENT) and os.environ.get("PAPER_KIT_TEST_STDIN") == "1"
if TEST_RECIPIENT:
    RECIPIENT = TEST_RECIPIENT

ARMOR_BEGIN = "-----BEGIN AGE ENCRYPTED FILE-----"
ARMOR_END = "-----END AGE ENCRYPTED FILE-----"
ARMOR_LINE = re.compile(r"^[A-Za-z0-9+/=]{1,64}$")

# Owner-supplied items: (id, group, label, kind, hint)
# kind: text | secret | lines (multi-line text) | secret-lines
#       | secret-key (an SSH private key: pasted or uploaded in the GUI, a file path in the CLI)
ITEMS = [
    ("copies", "This kit", "Where the printed copies are kept", "lines", ""),
    ("google_email", "Google", "Google account address", "text", ""),
    ("google_codes", "Google", "Google 2-step backup codes", "secret-lines", ""),
    ("github_user", "GitHub", "GitHub username", "text", "e.g. gilesknap"),
    ("github_codes", "GitHub", "GitHub recovery codes", "secret-lines", ""),
    ("cloudflare_email", "Cloudflare", "Cloudflare login email", "text", ""),
    ("cloudflare_codes", "Cloudflare", "Cloudflare recovery codes", "secret-lines", ""),
    ("backblaze_email", "Backblaze (B2)", "Backblaze login email", "text", ""),
    ("backblaze_codes", "Backblaze (B2)", "Backblaze 2FA recovery codes", "secret-lines", ""),
    ("backblaze_region", "Backblaze (B2)", "Backblaze account region", "text",
     "EU Central; the account's data lives in one region, chosen at sign-up"),
    ("anthropic_email", "Anthropic console (optional)", "Anthropic console login email",
     "text", "optional: only needed to replace scrap's API key"),
    ("anthropic_login", "Anthropic console (optional)", "How the Anthropic console logs in",
     "text", "optional: e.g. Google, or an emailed link"),
    ("tailscale_provider", "Tailscale", "Tailscale login provider", "text",
     "Google or GitHub"),
    ("registrar", "Domain registrar", "Registrar for gkcluster.org", "text",
     "skip if Cloudflare"),
    ("registrar_login", "Domain registrar", "Registrar login", "text", ""),
    ("registrar_password", "Domain registrar", "Registrar password", "secret", ""),
    ("hostinger_account", "Hostinger (VPS)", "Hostinger account (logs in via Google)",
     "text", "the Google address it uses"),
    ("hostinger_codes", "Hostinger (VPS)", "Hostinger 2FA recovery codes", "secret-lines",
     "Hostinger's own 2FA, separate from Google's"),
    ("vps_password", "Hostinger (VPS)", "Hostinger password (only if not logging in via Google)",
     "secret", "optional"),
    ("router_root", "OpenWrt router", "Router root password", "secret", ""),
    ("bmc", "Turing Pi BMC",
     "Turing Pi BMC root password (if you use a password rather than the SSH key)",
     "secret", "optional"),
    ("pwmgr_name", "Password manager", "Password manager name", "text", "optional"),
    ("pwmgr_master", "Password manager", "Password manager master password",
     "secret", "optional"),
    ("tofu_passphrase", "Cloudflare OpenTofu", "OpenTofu state passphrase", "secret",
     "cloudflare/.secrets/state-passphrase"),
    ("ssh_key", "SSH access", "SSH private key used by Ansible", "secret-key",
     "logs into the nodes as ansible and the Turing Pi BMC as root"),
    ("ssh_key_passphrase", "SSH access", "SSH key passphrase (if the key has one)", "secret",
     "optional"),
    ("notes", "Notes", "Free-text notes", "lines", ""),
]
ACCOUNT_GROUPS = ["Google", "GitHub", "Cloudflare", "Backblaze (B2)", "Tailscale",
                  "Domain registrar", "Hostinger (VPS)", "Anthropic console (optional)"]
SSH_GROUPS = ["SSH access"]
# Saved answers under retired keys: new key <- old keys (joined with "; ").
MIGRATE = {"hostinger_account": ("vps_login", "vps_provider")}
# The NAS has no password any more (Ubuntu, key-only SSH): the old QNAP
# answers and any other key not in ITEMS are dropped on load, and the next
# save removes them from answers.age.
LOCAL_GROUPS = ["OpenWrt router", "Turing Pi BMC", "Password manager",
                "Cloudflare OpenTofu"]


class KitError(Exception):
    """A user-facing failure; its message never contains a secret."""


def die(msg: str) -> None:
    raise KitError(msg)


def migrate_answers(saved: dict[str, str]) -> tuple[dict[str, str], bool]:
    """Move answers saved under retired keys to their new keys; (answers, changed)."""
    out = dict(saved)
    changed = False
    for new, olds in MIGRATE.items():
        vals = [out.pop(o) for o in olds if o in out]
        changed = changed or bool(vals)
        vals = [v for v in vals if v]
        if vals and not out.get(new):
            out[new] = "; ".join(vals)
    known = {k for k, *_ in ITEMS}
    for k in [k for k in out if k not in known]:
        del out[k]
        changed = True
    return out, changed


SSH_KEY_RE = re.compile(r"-----BEGIN ((?:[A-Z0-9]+ )*)PRIVATE KEY-----\n"
                        r"([A-Za-z0-9+/=:,. \n-]+?)\n-----END \1PRIVATE KEY-----")


def check_ssh_key(raw: str) -> str:
    """Normalise an OpenSSH/PEM private key (line ends, outer blanks); return it."""
    lines = [ln.rstrip() for ln in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    text = "\n".join(lines).strip("\n").strip()
    if not SSH_KEY_RE.fullmatch(text):
        die("that is not an SSH private key (expected -----BEGIN ... PRIVATE KEY----- "
            "... -----END ... PRIVATE KEY-----)")
    return text + "\n"


def _openssh_pub_blob(key: str) -> bytes:
    """The public key blob stored unencrypted in an openssh-key-v1 file, or b""."""
    import base64
    import struct
    m = SSH_KEY_RE.search(key)
    if not m or m.group(1) != "OPENSSH ":
        return b""
    try:
        b = base64.b64decode("".join(m.group(2).split()))
        magic = b"openssh-key-v1\0"
        if not b.startswith(magic):
            return b""
        i = len(magic)
        for _ in range(3):  # ciphername, kdfname, kdfoptions
            i += 4 + struct.unpack(">I", b[i:i + 4])[0]
        i += 4  # number of keys
        n = struct.unpack(">I", b[i:i + 4])[0]
        return b[i + 4:i + 4 + n]
    except (ValueError, struct.error):
        return b""


def _ssh_pub_blob(key: str) -> bytes:
    """The key's public half (wire-format blob), or b"" if it cannot be worked out.

    ssh-keygen gets the private key on stdin (never a file or argv); a key with a
    passphrase falls back to the public blob an OpenSSH-format file carries in clear.
    """
    import base64
    import shutil
    blob = b""
    if shutil.which("ssh-keygen"):
        try:
            p = subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", "/dev/stdin"],
                               input=key.encode(), capture_output=True, timeout=15,
                               check=False)
            parts = p.stdout.decode().split()
            if p.returncode == 0 and len(parts) >= 2:
                blob = base64.b64decode(parts[1])
        except (OSError, subprocess.TimeoutExpired, ValueError):
            blob = b""
    if not blob:
        blob = _openssh_pub_blob(key)
    return blob if len(blob) >= 4 else b""


def _blob_type(blob: bytes) -> str:
    n = int.from_bytes(blob[:4], "big")
    return blob[4:4 + n].decode("ascii", "replace")


def ssh_fingerprint(key: str) -> str:
    """'<type> SHA256:...' of the key's public half, or "" if it cannot be worked out."""
    import base64
    import hashlib
    blob = _ssh_pub_blob(key)
    if not blob:
        return ""
    fp = base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
    return f"{_blob_type(blob)} SHA256:{fp}"


def ssh_public_line(key: str) -> str:
    """The authorized_keys line ('<type> <base64>') for the key, or ""."""
    import base64
    blob = _ssh_pub_blob(key)
    if not blob:
        return ""
    return f"{_blob_type(blob)} {base64.b64encode(blob).decode()}"


# ------------------------------------------------------------------ prompts
def ask_secret(prompt: str) -> str:
    if TEST_STDIN:
        sys.stdout.write(prompt)
        sys.stdout.flush()
        line = sys.stdin.readline()
        if not line:
            die("unexpected end of test input")
        return line.rstrip("\n")
    return getpass.getpass(prompt)


def ask_text(prompt: str) -> str:
    try:
        return input(prompt)
    except EOFError:
        die("unexpected end of input")
        raise  # unreachable


# ------------------------------------------------------------------ age
def _with_identity(identity: str, argv: list[str], data: bytes) -> subprocess.CompletedProcess:
    """Run age with the identity on a pipe, as /dev/fd/N (never on disk or argv)."""
    r, w = os.pipe()
    try:
        os.write(w, identity.encode() + b"\n")
    finally:
        os.close(w)
    try:
        argv = [a.replace("{FD}", f"/dev/fd/{r}") for a in argv]
        return subprocess.run(argv, input=data, capture_output=True, pass_fds=(r,), check=False)
    finally:
        os.close(r)


def public_key_of(identity: str) -> str:
    p = subprocess.run(["age-keygen", "-y"], input=identity.encode() + b"\n",
                       capture_output=True, check=False)
    if p.returncode != 0:
        return ""
    return p.stdout.decode().strip()


def age_decrypt(identity: str, armored: str) -> bytes:
    p = _with_identity(identity, ["age", "-d", "-i", "{FD}"], armored.encode())
    if p.returncode != 0:
        die("age could not decrypt a data file: " + p.stderr.decode().strip())
    return p.stdout


def age_encrypt(plaintext: bytes) -> str:
    p = subprocess.run(["age", "-a", "-r", RECIPIENT], input=plaintext, capture_output=True,
                       check=False)
    if p.returncode != 0:
        die("age encryption failed: " + p.stderr.decode().strip())
    return p.stdout.decode()


# ------------------------------------------------------------------ data
def data_dir() -> Path:
    """The data directory, or a KitError saying how to make it."""
    if not DATA.is_dir():
        die(f"no paper-kit data directory at {DATA}. Run "
            "scripts/paper-kit/refresh-embedded.sh against the live cluster to create it, "
            "or set PAPER_KIT_DATA to where the kit's data is kept "
            "(see docs/how-to/paper-kit.md)")
    return DATA


def read_block(name: str) -> str:
    """The armored text of a data file (CLUSTER-CREDS or ANSWERS), or "" if none yet."""
    path = data_dir() / BLOCK_FILES[name]
    try:
        body = path.read_text().strip()
    except FileNotFoundError:
        return ""
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    return body + "\n" if body else ""


def kit_config() -> dict:
    """The optional plain-JSON facts in kit.json ({} if there is none)."""
    path = data_dir() / KIT_CONFIG
    try:
        cfg = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        die(f"cannot read {path}: {e}")
    if not isinstance(cfg, dict):
        die(f"{path} must hold a JSON object")
    return cfg


def check_armor(armored: str) -> str:
    lines = armored.strip().splitlines()
    if len(lines) < 3 or lines[0] != ARMOR_BEGIN or lines[-1] != ARMOR_END:
        die("not an ASCII-armored age file")
    if not all(ARMOR_LINE.match(ln) for ln in lines[1:-1]):
        die("armored block has unexpected content; refusing to store it")
    return "\n".join(lines) + "\n"


def write_block(name: str, armored: str) -> Path:
    """Replace a data file (CLUSTER-CREDS or ANSWERS) atomically, mode 0600."""
    armored = check_armor(armored) if armored.strip() else ""
    DATA.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = DATA / BLOCK_FILES[name]
    fd, tmp = tempfile.mkstemp(dir=DATA, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(armored)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        return path
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# ------------------------------------------------------------------ answers
def prompt_items(saved: dict[str, str]) -> dict[str, str]:
    print("\nFor each item: type a value, Enter to keep a saved one or skip,"
          " '-' to clear a saved one.")
    print("Multi-line items end on a blank line.\n")
    out: dict[str, str] = {}
    group = None
    for key, grp, label, kind, hint in ITEMS:
        if grp != group:
            print(f"== {grp} ==")
            group = grp
        has = bool(saved.get(key))
        tag = " [saved — Enter to keep]" if has else ""
        hint_s = f" ({hint})" if hint else ""
        ask = ask_secret if kind.startswith("secret") else ask_text
        if kind == "secret-key":
            value = ""
            while True:
                path = ask_text(f"{label}{hint_s}{tag}: path to the key file"
                                " (it is read, never shown): ").strip()
                if path in ("", "-"):
                    break
                try:
                    value = check_ssh_key(Path(path).expanduser().read_text())
                    break
                except OSError as e:
                    print(f"  cannot read that file ({e.strerror}); try again")
                except (KitError, UnicodeDecodeError) as e:
                    msg = str(e) if isinstance(e, KitError) else "not a text file"
                    print(f"  {msg}; try again")
            if path == "-":
                continue  # cleared
        elif kind in ("lines", "secret-lines"):
            print(f"{label}{hint_s}{tag}, one per line, blank line to finish:")
            lines: list[str] = []
            while True:
                ln = ask(f"  {len(lines) + 1}> ").strip()
                if not ln:
                    break
                if ln == "-" and not lines:
                    lines = None  # type: ignore[assignment]
                    break
                lines.append(ln)
            if lines is None:
                continue  # cleared
            value = "\n".join(lines)
        else:
            value = ask(f"{label}{hint_s}{tag}: ").strip()
            if value == "-":
                continue  # cleared
        if not value and has:
            value = saved[key]
        if value:
            out[key] = value
    return out


def maybe_save(answers: dict[str, str], saved: dict[str, str],
               migrated: bool = False) -> str | None:
    """Offer to save; return the save time, or None if not saved."""
    changed = answers != saved or migrated
    default = "Y/n" if changed else "y/N"
    note = "" if changed else " (unchanged)"
    reply = ask_text(f"\nSave these answers, encrypted, into {DATA / BLOCK_FILES['ANSWERS']}"
                     f"{note}? [{default}] ")
    reply = reply.strip().lower()
    yes = reply in ("y", "yes") or (reply == "" and changed)
    if not yes:
        print("Not saved.")
        return None
    now = save_answers(answers)
    print(f"Saved {len(answers)} answers (encrypted) into {BLOCK_FILES['ANSWERS']}.")
    return now


def save_answers(answers: dict[str, str]) -> str:
    """Encrypt the answers to RECIPIENT into answers.age; return the save time."""
    now = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    payload = json.dumps({"_saved": now, "answers": answers}).encode()
    write_block("ANSWERS", age_encrypt(payload))
    return now


# ------------------------------------------------------------------ inventory
def inventory() -> list[tuple[str, str, str]]:
    """(host, address, notes) from hosts.yml, kubectl (if reachable) and fixed facts."""
    rows: list[tuple[str, str, str]] = []
    ips: dict[str, str] = {}
    try:
        p = subprocess.run(
            ["kubectl", "get", "nodes", "-o",
             "jsonpath={range .items[*]}{.metadata.name}={.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}"],
            capture_output=True, text=True, timeout=15, check=False)
        if p.returncode == 0:
            for ln in p.stdout.splitlines():
                if "=" in ln:
                    k, v = ln.split("=", 1)
                    v4 = [a for a in v.split() if "." in a]
                    ips[k] = v4[0] if v4 else v.split()[0] if v.split() else ""
    except (OSError, subprocess.TimeoutExpired):
        pass
    hosts = REPO / "hosts.yml"
    if hosts.exists():
        group = ""
        cur: dict[str, str] | None = None
        for raw in hosts.read_text().splitlines():
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            ind = len(raw) - len(raw.lstrip())
            line = raw.split("#", 1)[0].rstrip()
            comment = raw.split("#", 1)[1].strip() if "#" in raw else ""
            if ind == 0:
                group = line.rstrip(":")
                cur = None
            elif ind == 4 and line.endswith(":") and group not in ("all_nodes", "routers"):
                name = line.strip().rstrip(":")
                if group == "controller":
                    continue
                if group == "turing_pis":
                    comment = "Turing Pi BMC (name from LAN DNS); ssh root@" + name
                cur = {"name": name, "group": group, "note": comment}
                if group == "nas":
                    cur["note"] = ("NAS (QNAP TS-253D hardware, Ubuntu Server + ZFS); "
                                   "ssh ansible@" + name + " (key only, no password); "
                                   "NFS export /bigdisk; cluster data in /bigdisk/k8s-cluster")
                rows.append(cur)  # type: ignore[arg-type]
            elif ind == 6 and cur is not None and ":" in line:
                k, v = (s.strip() for s in line.split(":", 1))
                if k in ("node_ip", "lan_ip"):
                    cur["ip"] = v
                elif k in ("type", "slot_num", "root_dev"):
                    cur["note"] = (cur["note"] + f"; {k} {v}").lstrip("; ")
                elif v == "true":
                    cur["note"] = (cur["note"] + f"; {k}").lstrip("; ")
        rows = [(r["name"], ips.get(r["name"], r.get("ip", "")),  # type: ignore[index]
                 f"{r['group']}: {r['note']}".rstrip(": ")) for r in rows]  # type: ignore[index]
    rows.append(("router (OpenWrt)", "192.168.1.1", "ssh root@192.168.1.1; LAN DNS (dnsmasq)"))
    return rows


# ------------------------------------------------------------------ PDF
def group_key(s: str, n: int = 5) -> list[str]:
    head = "AGE-SECRET-KEY-1"
    body = s.removeprefix(head)
    groups = [body[i:i + n] for i in range(0, len(body), n)]
    return [head] + [" ".join(groups[i:i + 4]) for i in range(0, len(groups), 4)]


def chunk_armor(armored: str, max_lines: int = 8) -> list[str]:
    lines = armored.strip().splitlines()
    return ["\n".join(lines[i:i + max_lines]) for i in range(0, len(lines), max_lines)]


def build_pdf(identity: str, answers: dict[str, str], creds_armored: str,
              creds: dict, answers_saved: str) -> bytes:
    from xml.sax.saxutils import escape

    from reportlab.graphics.barcode.qr import QrCodeWidget
    from reportlab.graphics.shapes import Drawing
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_LEFT
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import cm
    from reportlab.platypus import (
        CondPageBreak,
        KeepTogether,
        PageBreak,
        Paragraph,
        Preformatted,
        SimpleDocTemplate,
        Spacer,
        Table,
        TableStyle,
    )

    ss = getSampleStyleSheet()
    body = ParagraphStyle("b", parent=ss["BodyText"], fontSize=10, leading=13)
    small = ParagraphStyle("s", parent=body, fontSize=8.5, leading=11)
    h1 = ParagraphStyle("h1", parent=ss["Title"], fontSize=22, alignment=TA_LEFT)
    h2 = ParagraphStyle("h2", parent=ss["Heading2"], fontSize=14, spaceBefore=10)
    h3 = ParagraphStyle("h3", parent=ss["Heading3"], fontSize=11, spaceBefore=6, spaceAfter=2)
    keystyle = ParagraphStyle("k", fontName="Courier-Bold", fontSize=17, leading=24)
    mono = ParagraphStyle("m", fontName="Courier", fontSize=9.5, leading=12)
    tiny_mono = ParagraphStyle("tm", fontName="Courier", fontSize=6.6, leading=7.6)
    warn = ParagraphStyle("w", parent=body, fontSize=11, leading=14, borderWidth=1.2,
                          borderColor=colors.black, borderPadding=6, spaceBefore=8,
                          spaceAfter=8)

    def P(t: str, st=body) -> Paragraph:
        return Paragraph(t, st)

    def code(t: str) -> str:
        return f'<font face="Courier">{escape(t)}</font>'

    def qr(value: str, size: float) -> Drawing:
        w = QrCodeWidget(value, barLevel="M")
        x0, y0, x1, y1 = w.getBounds()
        d = Drawing(size, size, transform=[size / (x1 - x0), 0, 0, size / (y1 - y0), 0, 0])
        d.add(w)
        return d

    grid = TableStyle([("GRID", (0, 0), (-1, -1), 0.5, colors.black),
                       ("VALIGN", (0, 0), (-1, -1), "TOP"),
                       ("BACKGROUND", (0, 0), (0, -1), colors.whitesmoke)])

    today = dt.date.today().isoformat()
    pub = RECIPIENT
    story: list = []

    # ---- page 1
    story += [P("Home cluster — paper recovery kit", h1),
              P(f"Printed {today}. Answers last saved: {escape(answers_saved or 'never')}. "
                f"Cluster credentials generated: {escape(str(creds.get('_generated', 'not embedded')))}.")]
    story.append(P(
        "This kit rebuilds the home k3s cluster when the cluster, the NAS and the "
        "workstation are all lost. Its first page holds the one age key that decrypts "
        "every off-site backup and the credential appendix; the following pages hold the "
        "account recovery codes and local passwords needed to reach those backups, and "
        "the order to do things in."))
    if answers.get("copies"):
        story.append(P("<b>Copies of this kit are kept:</b> "
                       + escape(answers["copies"]).replace("\n", "<br/>")))
    story.append(P("<b>THIS KEY OPENS EVERYTHING.</b> Anyone holding this page can decrypt "
                   "every backup and credential. Store it like cash; never photograph it "
                   "to a cloud service.", warn))
    story.append(P("age private key (write to <b>key.txt</b> as one line, no spaces):", h3))
    key_par = [P(escape(ln), keystyle) for ln in group_key(identity)]
    key_tbl = Table([[key_par, qr(identity, 5.2 * cm)]], colWidths=[11.5 * cm, 5.8 * cm])
    key_tbl.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                                 ("BOX", (0, 0), (-1, -1), 1, colors.black)]))
    story += [key_tbl, Spacer(1, 4),
              P("Spaces are only for reading; the key is upper-case letters and digits "
                "(the bech32 alphabet has no B, I, O or the digit 1 after the first '1'). "
                "The QR code holds the exact key text.", small),
              P("Public key (the recipient every backup is encrypted to):", h3),
              P(escape(pub), mono),
              P("Check a typed key: " + code("age-keygen -y key.txt") +
                " must print the public key above.", small)]

    # ---- accounts
    def answer_rows(groups: list[str]) -> list:
        out: list = []
        for grp in groups:
            rows = []
            for key, g, label, kind, _hint in ITEMS:
                if g != grp:
                    continue
                if kind == "secret-key":
                    continue  # its own section
                v = answers.get(key, "")
                if not v:
                    cell = P("<i>(not recorded)</i>", small)
                elif kind.endswith("lines"):
                    cell = P(escape(v).replace("\n", "<br/>"),
                             mono if kind.startswith("secret") else body)
                elif kind == "secret":
                    cell = P(escape(v), mono)
                else:
                    cell = P(escape(v))
                rows.append([P(f"<b>{escape(label)}</b>", small), cell])
            t = Table(rows, colWidths=[5.2 * cm, 12.1 * cm])
            t.setStyle(grid)
            out.append(KeepTogether([P(grp, h3), t]))
        return out

    story += [PageBreak(), P("Account recovery", h2),
              P("Recover the Google account first: the off-site backups live in its Drive. "
                "Backblaze B2 holds the second off-site copy. "
                "Each recovery code works once; cross it out when used.", small)]
    story += answer_rows(ACCOUNT_GROUPS)
    story += [CondPageBreak(8 * cm), P("Local hardware and other passwords", h2)]
    story += answer_rows(LOCAL_GROUPS)
    if answers.get("notes"):
        story += [P("Notes", h3), P(escape(answers["notes"]).replace("\n", "<br/>"))]

    # ---- SSH access
    story += [PageBreak(), P("SSH access", h2),
              P("The SSH private key Ansible uses: it logs into every node as "
                + code("ansible") + " and into the Turing Pi BMC as " + code("root") + ".")]
    sshkey = answers.get("ssh_key", "")
    if not sshkey:
        story.append(P("<i>(SSH key not recorded)</i>"))
    else:
        fp = ssh_fingerprint(sshkey)
        if fp:
            story.append(P("Public key fingerprint: " + code(fp), small))
        pub = ssh_public_line(sshkey)
        if pub:
            story.append(P("Public key (one line, for <font face='Courier'>~/.ssh/authorized_keys</font>"
                           " or cloud-init; also rebuildable with "
                           + code("ssh-keygen -y -f id_cluster") + "):", small))
            story.append(Preformatted("\n".join(pub[i:i + 64] for i in range(0, len(pub), 64)),
                                      mono))
            story.append(P("<i>Type it as one line, without the line breaks.</i>", small))
        kchunks = chunk_armor(sshkey, 12)
        kn = len(kchunks)
        story.append(P("To use it:", h3))
        story.append(Preformatted(
            f"1. Scan the {kn} code{'s' if kn > 1 else ''} below in order"
            f"{' (1 of N, 2 of N, ...)' if kn > 1 else ''}.\n"
            "2. Paste them into a file id_cluster in that order, each starting on a\n"
            "   new line, ending with a newline. It starts with -----BEGIN ...\n"
            "   PRIVATE KEY----- and ends with -----END ... PRIVATE KEY-----\n"
            "3. chmod 600 id_cluster\n"
            "4. ssh -i id_cluster ansible@<node>        (any cluster node)\n"
            "   ssh -i id_cluster root@<bmc>            (the Turing Pi BMC)\n"
            "5. Check: ssh-keygen -lf id_cluster prints the fingerprint above.", mono))
        cells = [[qr(c, 7.6 * cm), P(f"<b>SSH key {i} of {kn}</b>", body)]
                 for i, c in enumerate(kchunks, 1)]
        rows = []
        for i in range(0, len(cells), 2):
            pair = cells[i:i + 2]
            rows.append([pair[0][0], pair[1][0] if len(pair) > 1 else ""])
            rows.append([pair[0][1], pair[1][1] if len(pair) > 1 else ""])
        st_ = Table(rows, colWidths=[8.6 * cm, 8.6 * cm])
        st_.setStyle(TableStyle([("ALIGN", (0, 0), (-1, -1), "CENTER"),
                                 ("VALIGN", (0, 0), (-1, -1), "MIDDLE")]))
        story += [Spacer(1, 6), st_, CondPageBreak(6 * cm),
                  P("Fallback: the key as text (only if the codes will not scan).", h3),
                  Preformatted(sshkey.rstrip("\n"), tiny_mono)]
    story += answer_rows(SSH_GROUPS)

    # ---- map
    story += [PageBreak(), P("Map and recovery order", h2)]
    folders = kit_config().get("extra_drive_folders", [])
    if not isinstance(folders, list):
        die(f"extra_drive_folders in {DATA / KIT_CONFIG} must be a list")
    extra_folders = "".join(
        f"folder {code(str(f.get('name', '')))} ({escape(str(f.get('what', '')))}); "
        for f in folders if isinstance(f, dict))
    steps = [
        ("<b>Google account.</b> Sign in with the address and a backup code from the "
        "account page (Google is also the login for anything set to 'Sign in with Google')."),
        "<b>Download from Google Drive:</b> folder " + code("home-cluster-offsite") +
        " (nightly encrypted off-site copy of the NAS backups); " + extra_folders +
        "and the sealed-secrets key export " + code("sealed-secrets-keys-YYYYMMDD.yaml.age") + ". "
        "If Drive is lost or its copy is damaged, the second off-site copy is in the "
        "Backblaze B2 bucket " + code("gk-cluster-offsite") + " (folder " + code("backups/") +
        ", same age encryption): sign in to Backblaze with the details on the account page.",
        "<b>Decrypt</b> with the key from page 1: save it as key.txt, then " +
        code("age -d -i key.txt file.age > file") + " for each file.",
        "<b>Rebuild.</b> Clone " + code("https://github.com/gilesknap/tpi-k3s-ansible") +
        "; start at " + code("docs/how-to/backup-restore.md") + ", then run the " +
        code("/rebuild-cluster") + " command (Claude Code, in the repo's devcontainer). "
        "Restore the sealed-secrets keys before ArgoCD syncs, so the committed "
        "SealedSecrets decrypt.",
        ("<b>External credentials</b> (GitHub OAuth, Cloudflare tokens, VPS relay, scrap, "
        "ntfy, Tailscale OAuth, admin password, the Drive and B2 off-site rclone configs) are in the appendix as encrypted QR codes; "
        "decrypt them with the same key."),
    ]
    for i, s in enumerate(steps, 1):
        story.append(P(f"{i}. {s}"))
    story.append(P("Network", h3))
    rows = [[P("<b>Host</b>", small), P("<b>Address</b>", small), P("<b>Notes</b>", small)]]
    for host, ip, note in inventory():
        rows.append([P(escape(host), small), P(escape(ip), small), P(escape(note), small)])
    t = Table(rows, colWidths=[3.8 * cm, 3.0 * cm, 10.5 * cm], repeatRows=1)
    t.setStyle(TableStyle([("GRID", (0, 0), (-1, -1), 0.5, colors.black),
                           ("BACKGROUND", (0, 0), (-1, 0), colors.whitesmoke),
                           ("VALIGN", (0, 0), (-1, -1), "TOP")]))
    story += [t, Spacer(1, 6),
              P("Cluster domain: " + code("gkcluster.org") + " (DNS and tunnel on Cloudflare). "
                "LAN API name: " + code("k3s.lan") + ". NAS data: " +
                code("/bigdisk/k8s-cluster") + " (backups in " +
                code("/bigdisk/k8s-cluster/backups") + ").", small)]

    # ---- appendix
    story += [PageBreak(), P("Appendix: cluster external credentials (encrypted)", h2)]
    if not creds_armored:
        story.append(P("<i>No credentials embedded. Run refresh-embedded.sh against the "
                       "live cluster, then re-run this script.</i>"))
    else:
        chunks = chunk_armor(creds_armored)
        n = len(chunks)
        names = sorted(k for k in creds if not k.startswith("_"))
        story.append(P(
            f"Generated {escape(str(creds.get('_generated', '?')))}. These are encrypted to the "
            f"key on page 1 (age, ASCII armor): typing long tokens from paper is impractical, "
            f"so scan them instead. {n} QR code{'s' if n > 1 else ''} hold the file in order."))
        story.append(P("To decrypt:", h3))
        story.append(Preformatted(
            "1. Scan each code in order (1 of N, 2 of N, ...).\n"
            "2. Paste them into creds.age in that order, each starting on a new line.\n"
            "   The file starts with -----BEGIN AGE ENCRYPTED FILE-----\n"
            "   and ends with -----END AGE ENCRYPTED FILE-----\n"
            "3. age -d -i key.txt creds.age > creds.json      (JSON: name -> value)\n"
            "4. To make the repo's .env:\n"
            "   jq -r 'to_entries[]|select(.key|startswith(\"_\")|not)|\"\\(.key)=\\(.value)\"' \\\n"
            "      creds.json > .env", mono))
        story.append(P(f"Names inside ({len(names)}): " +
                       ", ".join(code(k) for k in names), small))
        cells = []
        for i, c in enumerate(chunks, 1):
            cells.append([qr(c, 7.6 * cm), P(f"<b>{i} of {n}</b>", body)])
        rows = []
        for i in range(0, len(cells), 2):
            pair = cells[i:i + 2]
            rows.append([pair[0][0], pair[1][0] if len(pair) > 1 else ""])
            rows.append([pair[0][1], pair[1][1] if len(pair) > 1 else ""])
        qt = Table(rows, colWidths=[8.6 * cm, 8.6 * cm])
        qt.setStyle(TableStyle([("ALIGN", (0, 0), (-1, -1), "CENTER"),
                                ("VALIGN", (0, 0), (-1, -1), "MIDDLE")]))
        story += [Spacer(1, 6), qt, CondPageBreak(6 * cm),
                  P("Fallback: the same ciphertext as text (only if the codes will not scan).", h3),
                  Preformatted(creds_armored.strip(), tiny_mono)]

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.drawString(2 * cm, 1.2 * cm, f"Paper recovery kit — {today} — CONFIDENTIAL")
        canvas.drawRightString(A4[0] - 2 * cm, 1.2 * cm, f"page {doc.page}")
        canvas.restoreState()

    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, leftMargin=1.8 * cm, rightMargin=1.8 * cm,
                            topMargin=1.6 * cm, bottomMargin=1.8 * cm,
                            title="Paper recovery kit", author="")
    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    return buf.getvalue()


def write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, data)
    finally:
        os.close(fd)


# ------------------------------------------------------------------ GUI
GUI_PORT = 8765
GUI_IDLE = 30 * 60
if TEST_RECIPIENT and os.environ.get("PAPER_KIT_TEST_IDLE", "").isdigit():
    GUI_IDLE = int(os.environ["PAPER_KIT_TEST_IDLE"])
MAX_BODY = 512 * 1024
CREDS_STALE_DAYS = 30

# Form sections: (title, intro, groups); together they cover every ITEMS group.
SECTIONS = [
    ("Account recovery",
     ("Recovery codes and logins for the online accounts. Recover Google first: "
      "the off-site backups live in its Drive (Backblaze B2 holds the second copy)."),
     ACCOUNT_GROUPS),
    ("Local passwords", "Hardware on the LAN and other local secrets.", LOCAL_GROUPS),
    ("SSH access", ("The key Ansible uses for the nodes (as ansible) and the BMC (as root). "
                    "Paste it, or choose the key file: it is read in memory only."),
     SSH_GROUPS),
    ("Notes", "Printed on the first page and after the passwords.", ["This kit", "Notes"]),
]

CSS = """
:root{color-scheme:light dark;--bg:#f4f5f7;--card:#fff;--fg:#1c2230;--muted:#5b6474;
--line:#d6dbe3;--field:#fbfcfd;--accent:#2456c4;--accent-fg:#fff;--warn-bg:#fff3dc;
--warn:#7a4a00;--err-bg:#fde7e7;--err:#9c1c1c;--ok-bg:#e5f5ea;--ok:#1d6b35}
@media (prefers-color-scheme:dark){:root{--bg:#14171d;--card:#1d2129;--fg:#e5e8ee;
--muted:#9aa3b3;--line:#363d4a;--field:#171a20;--accent:#7ea4ff;--accent-fg:#0d1020;
--warn-bg:#3a2b10;--warn:#f2c46e;--err-bg:#3e1b1b;--err:#ffa0a0;--ok-bg:#16301f;
--ok:#8fd6a5}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,sans-serif}
main{max-width:46rem;margin:0 auto;padding:2rem 1rem 4rem}
h1{font-size:1.55rem;margin:0 0 .3rem}
h2{font-size:1.15rem;margin:0 0 .3rem}
h3{font-size:.78rem;margin:1.4rem 0 .4rem;color:var(--muted);text-transform:uppercase;
letter-spacing:.06em}
p{margin:.4rem 0}
.sub{color:var(--muted);margin:0 0 1rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;
padding:1.2rem 1.4rem;margin:1.2rem 0}
.field{margin:.9rem 0}
.lbl{display:block;font-weight:600;margin-bottom:.3rem}
.hint{color:var(--muted);font-weight:400;font-size:.88rem}
.badge{display:inline-block;font-size:.72rem;font-weight:600;padding:.05rem .45rem;
border-radius:99px;background:var(--ok-bg);color:var(--ok);margin-left:.4rem;
vertical-align:middle}
input[type=text],input[type=password],textarea{width:100%;padding:.5rem .65rem;
border:1px solid var(--line);border-radius:6px;background:var(--field);color:var(--fg);
font:inherit}
input:focus,textarea:focus{outline:2px solid var(--accent);outline-offset:-1px}
textarea{min-height:5.5rem;resize:vertical;
font:.9rem/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
input.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
textarea.masked{-webkit-text-security:disc}
.row{display:flex;gap:.5rem;align-items:flex-start}
.row>input,.row>textarea{flex:1}
button{font:inherit;cursor:pointer;border-radius:6px;padding:.5rem 1rem;
border:1px solid var(--accent);background:var(--accent);color:var(--accent-fg);
font-weight:600}
button.show{background:transparent;color:var(--accent);padding:.5rem .7rem;
font-weight:500;min-width:4.2rem}
.opt{display:block;font-size:.88rem;color:var(--muted);margin-top:.3rem}
.msg{border-radius:8px;padding:.7rem 1rem;margin:1rem 0}
.err{background:var(--err-bg);color:var(--err)}
.warn{background:var(--warn-bg);color:var(--warn)}
.ok{background:var(--ok-bg);color:var(--ok)}
.names{columns:2 14rem;margin:.5rem 0 0;padding-left:1.2rem;font-size:.88rem}
.names code,code{font:.85rem ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.actions{display:flex;gap:1rem;align-items:center;flex-wrap:wrap;margin-top:1rem}
ol.steps li{margin:.4rem 0}
"""

SHOW_JS = """
document.querySelectorAll('button.show').forEach(function (b) {
  b.addEventListener('click', function () {
    var f = document.getElementById(b.dataset.for);
    var shown;
    if (f.tagName === 'TEXTAREA') { shown = !f.classList.toggle('masked'); }
    else { shown = f.type === 'password'; f.type = shown ? 'text' : 'password'; }
    b.textContent = shown ? 'hide' : 'show';
  });
});
"""


def _h(s: object) -> str:
    import html
    return html.escape(str(s), quote=True)


def _page(title: str, body: str, nonce: str, script: bool = False, head: str = "") -> bytes:
    js = f'<script nonce="{nonce}">{SHOW_JS}</script>' if script else ""
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<meta name="referrer" content="no-referrer">{head}'
            f'<title>{_h(title)}</title><style nonce="{nonce}">{CSS}</style></head>'
            f'<body><main>{body}</main>{js}</body></html>').encode()


class GuiState:
    """Everything the session holds in memory; wipe() drops it all."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.identity: str | None = None
        self.creds_armored = ""
        self.creds: dict = {}
        self.ans_doc: dict = {}
        self.saved: dict[str, str] = {}
        self.pdf: bytes | None = None
        self.pdf_name = ""
        self.result = ""

    def wipe(self) -> None:
        with self.lock:
            self.identity = None
            self.creds.clear()
            self.saved.clear()
            self.ans_doc.clear()
            self.creds_armored = ""
            self.pdf = None
            self.result = ""


def _login_body(error: str = "") -> str:
    err = f'<div class="msg err">{_h(error)}</div>' if error else ""
    test = ('<div class="msg warn">TEST MODE: PAPER_KIT_TEST_RECIPIENT is set.</div>'
            if TEST_RECIPIENT else "")
    return f"""
<h1>Paper recovery kit</h1>
<p class="sub">Unlock with the cluster's age private key. It stays in this local
server's memory only, and is checked against the kit's public key.</p>
{test}{err}
<form class="card" method="post" action="key" autocomplete="off">
  <label class="lbl" for="key">age private key</label>
  <div class="row">
    <input type="password" id="key" name="key" class="mono" required autofocus
      autocomplete="off" spellcheck="false" autocapitalize="off"
      placeholder="AGE-SECRET-KEY-1…">
    <button type="button" class="show" data-for="key">show</button>
  </div>
  <p class="hint">Public key: <code>{_h(RECIPIENT)}</code></p>
  <div class="actions"><button type="submit">Unlock</button></div>
</form>"""


def _field_html(key: str, label: str, kind: str, hint: str, has_saved: bool) -> str:
    fid = f"f_{key}"
    secret = kind.startswith("secret")
    multi = kind.endswith("lines")
    ph = "saved — leave empty to keep" if has_saved else hint
    if multi and not has_saved:
        ph = (hint + "; " if hint else "") + "one per line"
    attrs = (f'id="{fid}" name="{fid}" placeholder="{_h(ph)}" autocomplete="off" '
             f'spellcheck="false" autocapitalize="off"')
    if kind == "secret-key":
        ctl = (f'<textarea {attrs} class="masked"></textarea>'
               f'<button type="button" class="show" data-for="{fid}">show</button>')
        ctl = (f'<div class="row">{ctl}</div><label class="opt">or choose the key file: '
               f'<input type="file" id="{fid}_file" name="{fid}_file"></label>')
        secret = False  # row and show button already added
    elif multi:
        cls = ' class="masked"' if secret else ""
        ctl = f"<textarea {attrs}{cls}></textarea>"
    else:
        typ = "password" if secret else "text"
        cls = ' class="mono"' if secret else ""
        ctl = f'<input type="{typ}" {attrs}{cls}>'
    if secret:
        ctl = f'<div class="row">{ctl}<button type="button" class="show" data-for="{fid}">show</button></div>'
    badge = '<span class="badge">saved</span>' if has_saved else ""
    hint_s = f' <span class="hint">({_h(hint)})</span>' if hint and has_saved else ""
    clear = (f'<label class="opt"><input type="checkbox" name="clear_{key}" value="1"> '
             f'clear saved value</label>' if has_saved else "")
    return (f'<div class="field"><label class="lbl" for="{fid}">{_h(label)}{hint_s}{badge}'
            f'</label>{ctl}{clear}</div>')


def _creds_html(st: GuiState) -> str:
    names = sorted(k for k in st.creds if not k.startswith("_"))
    gen = str(st.creds.get("_generated", ""))
    refresh = "<code>scripts/paper-kit/refresh-embedded.sh</code>"
    if not st.creds_armored:
        return (f'<div class="msg warn">No cluster credentials are embedded. Run {refresh} '
                f'against the live cluster, then reload this kit.</div>')
    age_s, stale = "", True
    try:
        when = dt.datetime.fromisoformat(gen)
        days = (dt.datetime.now(when.tzinfo) - when).days
        age_s = f" ({days} day{'s' if days != 1 else ''} ago)"
        stale = days > CREDS_STALE_DAYS
    except ValueError:
        pass
    if stale:
        note = (f'<div class="msg warn">These are more than {CREDS_STALE_DAYS} days old '
                f'or undated. Run {refresh}, then restart the kit, before printing.</div>')
    else:
        note = f'<p class="hint">If any have changed since, run {refresh} and restart the kit.</p>'
    items = "".join(f"<li><code>{_h(n)}</code></li>" for n in names)
    return (f'<div class="card"><h2>Cluster credentials</h2>'
            f'<p>{len(names)} credentials, generated {_h(gen or "at an unknown time")}{age_s}. '
            f'They go into the appendix as encrypted QR codes; names only are shown here.</p>'
            f'{note}<ul class="names">{items}</ul></div>')


def _form_body(st: GuiState, error: str = "") -> str:
    err = f'<div class="msg err">{_h(error)}</div>' if error else ""
    saved_at = st.ans_doc.get("_saved", "")
    saved_note = (f"{len(st.saved)} answers saved {_h(saved_at)}."
                  if st.saved else "No saved answers yet.")
    parts = [f"""
<h1>Paper recovery kit</h1>
<p class="sub">Key accepted. {saved_note} Fields with a saved value are left empty:
leave them empty to keep it, type to replace it, or tick "clear saved value".</p>
{err}{_creds_html(st)}
<form method="post" action="make" autocomplete="off" enctype="multipart/form-data">"""]
    for title, intro, groups in SECTIONS:
        parts.append(f'<section class="card"><h2>{_h(title)}</h2><p class="hint">{_h(intro)}</p>')
        for grp in groups:
            if len(groups) > 1:
                parts.append(f"<h3>{_h(grp)}</h3>")
            for key, g, label, kind, hint in ITEMS:
                if g == grp:
                    parts.append(_field_html(key, label, kind, hint, bool(st.saved.get(key))))
        parts.append("</section>")
    parts.append("""
<div class="card">
  <label><input type="checkbox" name="save" value="1" checked>
    Save my answers (encrypted, in the kit's data directory) for next time</label>
  <div class="actions"><button type="submit">Make the PDF</button>
  <span class="hint">The PDF downloads to your browser; nothing is written here.</span></div>
</div>
</form>""")
    return "".join(parts)


def _done_body(st: GuiState) -> str:
    return f"""
<h1>Your kit is downloading</h1>
<div class="msg ok">{_h(st.result)}</div>
<div class="card">
  <p>If the download did not start: <a href="pdf" download>{_h(st.pdf_name)}</a>.</p>
  <ol class="steps">
    <li>Print it.</li>
    <li>Check the QR codes scan with your phone (the key on page 1, and each appendix code).</li>
    <li>Then delete the PDF from Downloads (and empty the trash).</li>
  </ol>
  <form method="post" action="finish" class="actions">
    <button type="submit">Finish</button>
    <span class="hint">Stops the server and drops the key from memory.</span>
  </form>
  <p class="hint"><a href="./">Back to the form</a> to change something and make it again.</p>
</div>"""


def _answers_from_form(form: dict[str, str], saved: dict[str, str]) -> dict[str, str]:
    """Merge the submitted form over the saved answers (empty keeps, clear drops)."""
    out: dict[str, str] = {}
    for key, _g, _label, kind, _hint in ITEMS:
        raw = form.get(f"f_{key}", "")
        if kind == "secret-key":
            raw = form.get(f"f_{key}_file", "") or raw
            value = check_ssh_key(raw) if raw.strip() else ""
        elif kind.endswith("lines"):
            value = "\n".join(ln.strip() for ln in raw.splitlines() if ln.strip())
        else:
            value = raw.strip()
        if not value and not form.get(f"clear_{key}") and saved.get(key):
            value = saved[key]
        if value:
            out[key] = value
    return out


def parse_multipart(ctype: str, data: bytes) -> dict[str, str]:
    """Parse a multipart/form-data body in memory (stdlib email parser; no cgi)."""
    from email.parser import BytesParser
    from email.policy import HTTP
    head = f"Content-Type: {ctype}\r\nMIME-Version: 1.0\r\n\r\n".encode()
    msg = BytesParser(policy=HTTP).parsebytes(head + data)
    out: dict[str, str] = {}
    if not msg.is_multipart():
        return out
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name:
            continue
        payload = part.get_payload(decode=True) or b""
        out[str(name)] = payload.decode("utf-8", "replace")
    return out


def run_gui() -> None:
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import parse_qs

    token = secrets.token_urlsafe(24)
    prefix = f"/{token}"
    st = GuiState()
    last = [time.monotonic()]
    stopping = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        server_version = "paper-kit"
        sys_version = ""

        def log_message(self, format: str, *args: object) -> None:
            pass  # no access log: paths carry the token

        def _send(self, code: int, body: bytes, ctype: str = "text/html; charset=utf-8",
                  nonce: str = "", extra: dict[str, str] | None = None) -> None:
            self.send_response(code)
            src = f"'nonce-{nonce}'" if nonce else "'none'"
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Security-Policy",
                             f"default-src 'none'; style-src {src}; script-src {src}; "
                             "form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _html(self, title: str, body: str, code: int = 200, script: bool = False,
                  head: str = "") -> None:
            nonce = secrets.token_urlsafe(16)
            self._send(code, _page(title, body, nonce, script, head), nonce=nonce)

        def _redirect(self, sub: str) -> None:
            self._send(303, b"", "text/plain", extra={"Location": f"{prefix}/{sub}"})

        def _route(self) -> str | None:
            """The path after the token, or None after sending a refusal."""
            # Any port: VS Code's port forwarding may map the server to another
            # local port. The one-time token below is the real gate.
            host = self.headers.get("Host", "").rsplit(":", 1)[0]
            if host not in ("127.0.0.1", "localhost", "[::1]"):
                print(f"refused: Host {host!r}", file=sys.stderr)
                self._send(403, b"forbidden: open the link via localhost or 127.0.0.1\n", "text/plain")
                return None
            path = self.path.split("?", 1)[0]
            if path == prefix:
                self._redirect("")
                return None
            if not path.startswith(prefix + "/"):
                self._send(403, b"forbidden: use the full link printed in the terminal (it includes a one-time token)\n", "text/plain")
                return None
            site = self.headers.get("Sec-Fetch-Site")
            if self.command == "POST" and site not in (None, "same-origin", "none"):
                print(f"refused: cross-site POST ({site!r})", file=sys.stderr)
                self._send(403, b"forbidden: cross-site request\n", "text/plain")
                return None
            last[0] = time.monotonic()
            return path[len(prefix):]

        def _form(self) -> dict[str, str] | None:
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = -1
            if n < 0 or n > MAX_BODY:
                self._send(413, b"too large\n", "text/plain")
                return None
            data = self.rfile.read(n)
            ctype = self.headers.get("Content-Type", "")
            if ctype.lower().startswith("multipart/form-data"):
                return parse_multipart(ctype, data)
            raw = data.decode("utf-8", "replace")
            return {k: v[-1] for k, v in parse_qs(raw, keep_blank_values=True).items()}

        def do_HEAD(self) -> None:
            self.do_GET()

        def do_GET(self) -> None:
            sub = self._route()
            if sub is None:
                return
            with st.lock:
                if sub == "/":
                    if st.identity is None:
                        self._html("Paper kit: unlock", _login_body(), script=True)
                    else:
                        self._html("Paper kit", _form_body(st), script=True)
                elif sub in ("/done", "/pdf") and st.pdf is None:
                    self._redirect("")
                elif sub == "/done":
                    self._html("Paper kit: done", _done_body(st),
                               head='<meta http-equiv="refresh" content="0;url=pdf">')
                elif sub == "/pdf":
                    self._send(200, st.pdf, "application/pdf", extra={
                        "Content-Disposition": f'attachment; filename="{st.pdf_name}"'})
                else:
                    self._send(404, b"not found\n", "text/plain")

        def do_POST(self) -> None:
            sub = self._route()
            if sub is None:
                return
            form = self._form()
            if form is None:
                return
            with st.lock:
                if sub == "/key":
                    self._post_key(form)
                elif sub == "/finish":
                    self._html("Paper kit: stopped", "<h1>Stopped</h1><div class=\"card\">"
                               "<p>The kit server has stopped and dropped the key and answers "
                               "from memory. You can close this tab.</p><p>Remember to delete "
                               "the PDF from Downloads once it is printed.</p></div>")
                    stopping.set()
                elif st.identity is None:
                    self._redirect("")
                elif sub == "/make":
                    self._post_make(form)
                else:
                    self._send(404, b"not found\n", "text/plain")
            form.clear()

        def _post_key(self, form: dict[str, str]) -> None:
            if st.identity is not None:
                self._redirect("")
                return
            try:
                identity = check_identity(form.get("key", ""))
                st.creds_armored, st.creds, st.ans_doc = load_embedded(identity)
            except KitError as e:
                self._html("Paper kit: unlock", _login_body(str(e)), script=True)
                return
            st.identity = identity
            st.saved = dict(st.ans_doc.get("answers", {}))
            print("Key accepted.", file=sys.stderr)
            self._redirect("")

        def _post_make(self, form: dict[str, str]) -> None:
            assert st.identity is not None
            answers: dict[str, str] = {}
            try:
                answers = _answers_from_form(form, st.saved)
                changed = answers != st.saved or bool(st.ans_doc.get("_migrated"))
                if form.get("save") and changed:
                    saved_at = save_answers(answers)
                    st.ans_doc = {"_saved": saved_at, "answers": dict(answers)}
                    st.saved = dict(answers)
                    how = f"Answers saved (encrypted) into {BLOCK_FILES['ANSWERS']}."
                elif form.get("save"):
                    saved_at = st.ans_doc.get("_saved", "")
                    how = f"Answers unchanged, so {BLOCK_FILES['ANSWERS']} was not rewritten."
                else:
                    saved_at = st.ans_doc.get("_saved", "") if not changed else "not saved"
                    how = "Answers not saved."
                pdf = build_pdf(st.identity, answers, st.creds_armored, st.creds, saved_at)
            except KitError as e:
                self._html("Paper kit", _form_body(st, str(e)), script=True)
                return
            finally:
                answers_n = sum(1 for k, *_ in ITEMS if answers.get(k))
                answers.clear()
            names = [k for k in st.creds if not k.startswith("_")]
            st.pdf = pdf
            st.pdf_name = f"paper-kit-{dt.date.today():%Y%m%d}.pdf"
            st.result = (f"{answers_n} of {len(ITEMS)} items filled, {len(names)} cluster "
                         f"credentials in the appendix. {how}")
            print(st.result, file=sys.stderr)
            self._redirect("done")

    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", GUI_PORT), Handler)
    except OSError:
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]

    def watchdog() -> None:
        while not stopping.wait(min(5.0, GUI_IDLE / 4)):
            if time.monotonic() - last[0] > GUI_IDLE:
                print(f"Idle for {GUI_IDLE // 60 or GUI_IDLE} "
                      f"{'minutes' if GUI_IDLE >= 60 else 'seconds'}: stopping.",
                      file=sys.stderr)
                break
        httpd.shutdown()

    threading.Thread(target=watchdog, daemon=True).start()
    print(f"http://127.0.0.1:{port}{prefix}/", flush=True)
    print("Open that URL in a browser on this machine. Ctrl-C to stop.", file=sys.stderr)
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        stopping.set()
        httpd.server_close()
        st.wipe()
        print("Stopped; key and answers dropped from memory.", file=sys.stderr)


# ------------------------------------------------------------------ main
def splice_creds() -> None:
    armored = sys.stdin.read()
    path = write_block("CLUSTER-CREDS", check_armor(armored))
    print(f"Wrote the cluster credentials (encrypted) to {path}")


def check_identity(raw: str) -> str:
    """Normalise a typed key and check it is the cluster key; return it."""
    identity = "".join(raw.split()).upper()
    if not identity.startswith("AGE-SECRET-KEY-1"):
        die("that is not an age private key (it should start AGE-SECRET-KEY-1)")
    if public_key_of(identity) != RECIPIENT:
        die("that key is not the cluster key (its public key does not match RECIPIENT)")
    return identity


def load_embedded(identity: str) -> tuple[str, dict, dict]:
    """Decrypt the data files: (creds armor, creds JSON, answers document)."""
    creds_armored = read_block("CLUSTER-CREDS")
    creds = json.loads(age_decrypt(identity, creds_armored)) if creds_armored else {}
    ans_armored = read_block("ANSWERS")
    ans_doc = json.loads(age_decrypt(identity, ans_armored)) if ans_armored else {}
    if ans_doc.get("answers"):
        ans_doc["answers"], migrated = migrate_answers(ans_doc["answers"])
        if migrated:
            ans_doc["_migrated"] = True
    return creds_armored, creds, ans_doc


def main() -> None:
    args = sys.argv[1:]
    if args[:1] == ["--splice-creds"]:
        splice_creds()
        return
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return
    if TEST_RECIPIENT:
        print("*** TEST MODE: PAPER_KIT_TEST_RECIPIENT is set ***", file=sys.stderr)
    data_dir()  # fail before asking for anything if there is no data
    kit_config()
    if args[:1] == ["--gui"]:
        run_gui()
        return
    if args[:1] == ["--cli"]:
        args = args[1:]
    out = Path(args[0]) if args else Path.home() / f"paper-kit-{dt.date.today():%Y%m%d}.pdf"

    identity = check_identity(ask_secret("age private key (AGE-SECRET-KEY-1...): "))
    print("Key accepted.")

    creds_armored, creds, ans_doc = load_embedded(identity)
    saved = ans_doc.get("answers", {})
    names = [k for k in creds if not k.startswith("_")]
    print(f"Data: {len(names)} cluster credentials"
          f" (generated {creds.get('_generated', 'never')}); {len(saved)} saved answers.")

    answers = prompt_items(saved)
    saved_at = maybe_save(answers, saved, bool(ans_doc.get("_migrated")))
    if saved_at is None:
        saved_at = ans_doc.get("_saved", "") if answers == saved else "not saved"

    pdf = build_pdf(identity, answers, creds_armored, creds, saved_at)
    write_private(out, pdf)
    filled = [k for k, *_ in ITEMS if answers.get(k)]
    print(f"\nWrote {out} (mode 0600): {len(filled)} of {len(ITEMS)} items filled,"
          f" {len(names)} cluster credentials in the appendix.")
    print("Now: print it (check the QR codes scan), then delete the PDF:")
    print(f"  shred -u '{out}'")


if __name__ == "__main__":
    try:
        main()
    except KitError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
