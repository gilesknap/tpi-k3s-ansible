"""Build the data of the ntfy-auth Secret (namespace ntfy).

Shared by scripts/generate-secrets (rebuild) and scripts/seal-ntfy (first
seal and rotation), so both produce the same keys:

- NTFY_AUTH_USERS: "<user>:<bcrypt-hash>:<role>", comma-separated, read by
  ntfy as the declarative auth-users list;
- NTFY_AUTH_TOKENS: "<user>:<token>:<label>", comma-separated (auth-tokens);
- admin-password and <user>-token for each client: the plain values, for
  the owner (scripts/ntfy-tokens) and later in-cluster publishers.

The access list (auth-access) is not secret and lives in
kubernetes-services/additions/ntfy/values.yaml; every user it names must be
in USERS here.

Client users authenticate with tokens only, so their passwords are random
and thrown away. Hashing uses htpasswd (apache2-utils, in the devcontainer),
with the password on stdin, never on a command line.
"""

from __future__ import annotations

import re
import secrets
import string
import subprocess

# user -> ntfy role. Only "user" roles can hold access entries; "admin" has
# access to every topic.
USERS = {
    "admin": "admin",
    "alertmanager": "user",
    "vps": "user",
    "phone": "user",
}
# Users that get an access token, in this order.
TOKEN_USERS = ("alertmanager", "vps", "phone")

# ntfy's own rule (user/util.go): "tk_" plus 29 characters, 32 in all.
TOKEN_RE = re.compile(r"^tk_[-_A-Za-z0-9]{29}$")
BCRYPT_COST = "10"  # ntfy's minimum (DefaultUserPasswordBcryptCost)


def new_token() -> str:
    """A new token in the form `ntfy token generate` makes (lower-case alnum)."""
    alphabet = string.ascii_lowercase + string.digits
    return "tk_" + "".join(secrets.choice(alphabet) for _ in range(29))


def new_password() -> str:
    return secrets.token_urlsafe(24)


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
    # Same normalisation as scripts/set-admin-password; ntfy accepts both.
    return hash_.replace("$2y$", "$2a$", 1)


def secret_data(admin_password: str, tokens: dict[str, str]) -> dict[str, str]:
    """The ntfy-auth Secret data, from the admin password and the client tokens."""
    if not admin_password:
        raise ValueError("ntfy admin password is empty")
    for user in TOKEN_USERS:
        if not TOKEN_RE.match(tokens.get(user, "")):
            raise ValueError(
                f"ntfy token for {user!r} is missing or not in ntfy's form "
                "(tk_ plus 29 letters, digits, - or _)"
            )
    users = []
    for user, role in USERS.items():
        password = admin_password if user == "admin" else new_password()
        users.append(f"{user}:{bcrypt_hash(password)}:{role}")
    data = {
        "NTFY_AUTH_USERS": ",".join(users),
        "NTFY_AUTH_TOKENS": ",".join(f"{u}:{tokens[u]}:{u}" for u in TOKEN_USERS),
        "admin-password": admin_password,
    }
    for user in TOKEN_USERS:
        data[f"{user}-token"] = tokens[user]
    return data
