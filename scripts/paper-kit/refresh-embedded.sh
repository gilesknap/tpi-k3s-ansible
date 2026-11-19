#!/usr/bin/env bash
# Regenerate the paper kit's cluster-creds.age from the live cluster: the
# set scripts/export-external-creds exports (incl. the ntfy per-user tokens
# and both off-site rclone configs, Drive and B2), the Tailscale OAuth client
# in $TS_OAUTH_FILE (default _claude/.ts-oauth, gitignored) and the admin
# password (monitoring/admin-auth). The JSON is built in memory, piped to
# `age -a -r RECIPIENT`, and only the armored ciphertext is written, to the
# kit's data directory (_claude/paper-kit-data/, or $PAPER_KIT_DATA; created
# if missing). Prints key names and counts, never values.
# See docs/how-to/paper-kit.md.
#
# Usage: scripts/paper-kit/refresh-embedded.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
kit="$here/make-paper-kit.py"
ts_oauth=${TS_OAUTH_FILE:-$repo/_claude/.ts-oauth}
export PATH="$HOME/bin:$PATH"  # age, as run.sh

# The recipient is the one in the kit script; a test override is never
# honoured here, and it must match the cluster's age key in group_vars.
recipient=$(sed -n 's/^RECIPIENT = "\(age1[a-z0-9]*\)"$/\1/p' "$kit")
expected=$(sed -n 's/^etcd_backup_age_recipient: "\(age1[a-z0-9]*\)".*/\1/p' "$repo/group_vars/all.yml")
if [ -z "$recipient" ] || [ "$recipient" != "$expected" ]; then
    echo "error: RECIPIENT in $kit does not match etcd_backup_age_recipient" >&2
    exit 1
fi

ntfy_users=$(python3 "$repo/scripts/lib/ntfy_auth.py" users)

armored=$(
    NTFY_USERS="$ntfy_users" TS_OAUTH_FILE="$ts_oauth" python3 -I -c '
import base64, datetime, json, os, subprocess, sys

def secret(ns, name):
    p = subprocess.run(["kubectl", "get", "secret", name, "-n", ns, "-o", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return {}
    return json.loads(p.stdout).get("data") or {}

cache = {}
def get(ns, name, key):
    if (ns, name) not in cache:
        cache[(ns, name)] = secret(ns, name)
    v = cache[(ns, name)].get(key)
    return base64.b64decode(v).decode() if v else ""

# (env name, namespace, secret, key): as scripts/export-external-creds
spec = [
    ("GITHUB_CLIENT_ID", "argo-cd", "argocd-dex-secret", "dex.github.clientID"),
    ("GITHUB_CLIENT_SECRET", "argo-cd", "argocd-dex-secret", "dex.github.clientSecret"),
    ("CLOUDFLARE_API_TOKEN", "cert-manager", "cloudflare-api-token", "api-token"),
    ("CLOUDFLARE_TUNNEL_TOKEN", "cloudflared", "cloudflared-credentials", "TUNNEL_TOKEN"),
    ("OAUTH2_PROXY_CLIENT_ID", "oauth2-proxy", "oauth2-proxy-credentials", "client-id"),
    ("OAUTH2_PROXY_CLIENT_SECRET", "oauth2-proxy", "oauth2-proxy-credentials", "client-secret"),
    ("VPS_RELAY_TS_OAUTH_CLIENT_SECRET", "vps-relay", "vps-relay-credentials", "ts-oauth-client-secret"),
    ("VPS_RELAY_FRP_TOKEN", "vps-relay", "vps-relay-credentials", "frp-token"),
    ("SCRAP_ANTHROPIC_API_KEY", "scrap", "scrap-secrets", "ANTHROPIC_API_KEY"),
    ("SCRAP_MCP_TOKEN", "scrap", "scrap-secrets", "SCRAP_MCP_TOKEN"),
    ("SCRAP_MCP_TOKEN_CANARY", "scrap", "scrap-secrets", "SCRAP_MCP_TOKEN_CANARY"),
    ("SCRAP_PUBLISH_TOKEN", "scrap", "scrap-publish", "token"),
]
for user in os.environ["NTFY_USERS"].split():
    spec.append((f"NTFY_{user.upper()}_TOKEN", "ntfy", "ntfy-auth", f"{user}-token"))
spec.append(("ADMIN_PASSWORD", "monitoring", "admin-auth", "password"))

out, missing = {}, []
for env, ns, name, key in spec:
    v = get(ns, name, key)
    if v:
        out[env] = v
    else:
        missing.append(env)

# The rclone.conf of each off-site backup (Drive token; B2 application key),
# base64 as scripts/export-external-creds exports them, so a restore can drop
# them into .env.
for env, name in (("OFFSITE_BACKUP_RCLONE_CONF_B64", "offsite-backup-rclone"),
                  ("OFFSITE_BACKUP_B2_RCLONE_CONF_B64", "offsite-backup-b2")):
    v = get("backups", name, "rclone.conf")
    if v:
        out[env] = base64.b64encode(v.encode()).decode()
    else:
        missing.append(env)

ts = os.environ["TS_OAUTH_FILE"]
if os.path.exists(ts):
    with open(ts) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.removeprefix("export ").split("=", 1)
            v = v.strip().strip("\"").strip("\x27")
            if v:
                out[k.strip()] = v
else:
    missing.append(f"TS_CLIENT_ID/TS_CLIENT_SECRET (no {ts})")

if len(out) < 5:
    sys.exit(f"error: only {len(out)} credentials read; is kubectl pointed at the cluster?")

out["_generated"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
names = sorted(k for k in out if not k.startswith("_"))
print(f"{len(names)} credentials: " + " ".join(names), file=sys.stderr)
if missing:
    print("missing (skipped): " + " ".join(missing), file=sys.stderr)

recipient = sys.argv[1]
p = subprocess.run(["age", "-a", "-r", recipient], input=json.dumps(out).encode(),
                   capture_output=True)
if p.returncode != 0:
    sys.exit("error: age failed: " + p.stderr.decode())
sys.stdout.write(p.stdout.decode())
' "$recipient"
)

printf '%s\n' "$armored" | python3 "$kit" --splice-creds
