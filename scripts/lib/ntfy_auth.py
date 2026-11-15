"""Build the data of the ntfy-auth Secret (namespace ntfy).

SENDERS below is the one list of ntfy's users. Everything else derives from
it: scripts/seal-ntfy and scripts/generate-secrets (through secret_data),
and the bash scripts seal-from-json, export-external-creds and ntfy-tokens
(through `scripts/lib/ntfy_auth.py users [--owner | --env]`), and the
cluster role's rebuild task (`users --env`). To add or remove a
sender, change SENDERS here and the `access` list in
kubernetes-services/additions/ntfy/values.yaml (every user named there must
be here, or ntfy refuses to start).

The Secret's keys:

- NTFY_AUTH_USERS: "<user>:<bcrypt-hash>:user", comma-separated, read by
  ntfy as the declarative auth-users list;
- NTFY_AUTH_TOKENS: "<user>:<token>:<user>", comma-separated (auth-tokens);
- <user>-token for each user: the plain token, for the owner
  (scripts/ntfy-tokens), in-cluster publishers and the rebuild export.

An in-cluster publisher in another namespace cannot read ntfy-auth, so its
token is also sealed into a Secret of its own (CLUSTER_COPIES, key `token`)
wherever ntfy-auth is sealed: scripts/seal-ntfy and scripts/seal-from-json
(through `ntfy_auth.py copies`). A publisher that can only POST to a URL,
with no header of its own, also gets key `url`: its topic URL with the token
in ntfy's `?auth=` query parameter (COPY_URLS, copy_data, and
`ntfy_auth.py copy-url USER` for the bash scripts).

There is no admin user: auth is declarative, so nothing needs one. Users
authenticate with tokens only, so their passwords are random and thrown
away. Hashing uses htpasswd (apache2-utils, in the devcontainer), with the
password on stdin, never on a command line.
"""

from __future__ import annotations

import base64
import re
import secrets
import string
import subprocess
import sys

# user -> who holds its token. "owner" tokens are handed out by hand (the
# owner reads them with `just ntfy-tokens`); "cluster" tokens are read from
# the Secret by an in-cluster publisher and never printed.
SENDERS = {
    "alertmanager": "cluster",
    "scrap": "cluster",
    "vps": "owner",
    "phone": "owner",
}
TOKEN_USERS = tuple(SENDERS)

# "cluster" user -> (namespace, Secret name, SealedSecret file from the repo
# root) of the copy of its token that its publisher mounts, as key `token`.
CLUSTER_COPIES = {
    "alertmanager": (
        "monitoring",
        "alertmanager-ntfy",
        "kubernetes-services/additions/grafana/alertmanager-ntfy-secret.yaml",
    ),
    "scrap": (
        "scrap",
        "scrap-ntfy",
        "kubernetes-services/additions/scrap/templates/scrap-ntfy-secret.yaml",
    ),
}

# CLUSTER_COPIES user -> the topic URL its publisher POSTs to. Its copy then
# also holds key `url`: this URL with the token in ntfy's `?auth=` query
# parameter, for a publisher that cannot set an Authorization header (scrap
# reads it as SCRAP_NOTIFY_URL and sends a bare POST).
COPY_URLS = {
    "scrap": "http://ntfy.ntfy.svc.cluster.local/cluster-alerts",
}

# Names become env vars (NTFY_<USER>_TOKEN) and Secret keys.
USER_RE = re.compile(r"^[a-z][a-z0-9]*$")
# ntfy's own rule (user/util.go): "tk_" plus 29 characters, 32 in all.
TOKEN_RE = re.compile(r"^tk_[-_A-Za-z0-9]{29}$")
BCRYPT_COST = "10"  # ntfy's minimum (DefaultUserPasswordBcryptCost)

for _user in SENDERS:
    if not USER_RE.match(_user):
        raise ValueError(f"ntfy user name {_user!r} must match {USER_RE.pattern}")
for _user in CLUSTER_COPIES:
    if SENDERS.get(_user) != "cluster":
        raise ValueError(f"CLUSTER_COPIES names {_user!r}, not a cluster sender")
for _user in COPY_URLS:
    if _user not in CLUSTER_COPIES:
        raise ValueError(f"COPY_URLS names {_user!r}, which has no CLUSTER_COPIES entry")


def env_name(user: str) -> str:
    """The rebuild env var holding `user`'s token."""
    return f"NTFY_{user.upper()}_TOKEN"


def new_token() -> str:
    """A new token in the form `ntfy token generate` makes (lower-case alnum)."""
    alphabet = string.ascii_lowercase + string.digits
    return "tk_" + "".join(secrets.choice(alphabet) for _ in range(29))


def bcrypt_hash(password: str) -> str:
    """bcrypt hash of `password`, via htpasswd reading it from stdin."""
    out = subprocess.run(
        ["htpasswd", "-niBC", BCRYPT_COST, "ntfy"],
        input=password + "\n",
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    hash_ = out.split(":", 1)[1]
    # Normalise $2y$ (htpasswd) to $2a$; ntfy accepts both.
    return hash_.replace("$2y$", "$2a$", 1)


def auth_url(url: str, token: str) -> str:
    """`url` with `token` in ntfy's `?auth=` query parameter: the
    Authorization header value, "Bearer <token>", base64url-encoded without
    padding (ntfy decodes it with RawURLEncoding)."""
    if not TOKEN_RE.match(token):
        raise ValueError("ntfy token is not in ntfy's form")
    auth = base64.urlsafe_b64encode(f"Bearer {token}".encode()).decode().rstrip("=")
    return f"{url}{'&' if '?' in url else '?'}auth={auth}"


def copy_data(user: str, token: str) -> dict[str, str]:
    """The data of `user`'s CLUSTER_COPIES Secret: `token`, and `url` if the
    user is in COPY_URLS."""
    data = {"token": token}
    if user in COPY_URLS:
        data["url"] = auth_url(COPY_URLS[user], token)
    return data


def secret_data(tokens: dict[str, str]) -> dict[str, str]:
    """The ntfy-auth Secret data, from each user's token."""
    for user in TOKEN_USERS:
        if not TOKEN_RE.match(tokens.get(user, "")):
            raise ValueError(
                f"ntfy token for {user!r} is missing or not in ntfy's form "
                "(tk_ plus 29 letters, digits, - or _)"
            )
    data = {
        "NTFY_AUTH_USERS": ",".join(
            f"{u}:{bcrypt_hash(secrets.token_urlsafe(24))}:user" for u in TOKEN_USERS
        ),
        "NTFY_AUTH_TOKENS": ",".join(f"{u}:{tokens[u]}:{u}" for u in TOKEN_USERS),
    }
    for user in TOKEN_USERS:
        data[f"{user}-token"] = tokens[user]
    return data


def main(argv: list[str]) -> None:
    """`ntfy_auth.py users [--owner | --env]`, one per line: every user, the
    users whose tokens the owner hands out, or every user's rebuild env var.
    `ntfy_auth.py copies`: one "<user> <namespace> <name> <file>" line per
    entry in CLUSTER_COPIES. `ntfy_auth.py copy-url USER`: USER's `url` (see
    copy_data) from the token on stdin, or nothing if USER has none."""
    if argv == ["copies"]:
        for user, (namespace, name, path) in CLUSTER_COPIES.items():
            print(user, namespace, name, path)
        return
    if len(argv) == 2 and argv[0] == "copy-url" and argv[1] in CLUSTER_COPIES:
        url = copy_data(argv[1], sys.stdin.read().strip()).get("url")
        if url:
            print(url)
        return
    if argv[:1] != ["users"] or argv[1:] not in ([], ["--owner"], ["--env"]):
        sys.exit("usage: ntfy_auth.py users [--owner | --env] | copies | copy-url USER")
    for user, holder in SENDERS.items():
        if argv[1:] == ["--env"]:
            print(env_name(user))
        elif argv[1:] == [] or holder == "owner":
            print(user)


if __name__ == "__main__":
    main(sys.argv[1:])
