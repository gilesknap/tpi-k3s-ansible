"""OAuth Authorization Server that delegates authentication to GitHub.

Implements the authorization code flow with PKCE, issuing JWT bearer tokens
to authenticated users whose GitHub username is on the allowlist.
"""

from __future__ import annotations

import hashlib
import base64
import os
import secrets
import time
from urllib.parse import urlencode

import httpx
import jwt
from starlette.requests import Request
from starlette.responses import JSONResponse, RedirectResponse, Response
from starlette.routing import Route

# ---------------------------------------------------------------------------
# Configuration (read from env)
# ---------------------------------------------------------------------------

GITHUB_CLIENT_ID = os.environ.get("GITHUB_CLIENT_ID", "")
GITHUB_CLIENT_SECRET = os.environ.get("GITHUB_CLIENT_SECRET", "")
GITHUB_ALLOWED_USERS = {
    u.strip()
    for u in os.environ.get("GITHUB_ALLOWED_USERS", "").split(",")
    if u.strip()
}
MCP_JWT_SECRET = os.environ.get("MCP_JWT_SECRET", "")
SERVER_URL = os.environ.get("SERVER_URL", "http://localhost:8000")

AUTH_CODE_TTL = 300  # 5 minutes
BEARER_TOKEN_TTL = 86400  # 24 hours

# ---------------------------------------------------------------------------
# In-memory stores
# ---------------------------------------------------------------------------

# Pending authorization requests keyed by the state parameter we send to
# GitHub.  Value contains the original client params plus PKCE challenge.
_pending: dict[str, dict] = {}

# Issued authorization codes keyed by the code string.
_auth_codes: dict[str, dict] = {}


# ---------------------------------------------------------------------------
# Route handlers
# ---------------------------------------------------------------------------

async def well_known_metadata(request: Request) -> JSONResponse:
    """RFC 8414 OAuth Authorization Server Metadata."""
    return JSONResponse({
        "issuer": SERVER_URL,
        "authorization_endpoint": f"{SERVER_URL}/authorize",
        "token_endpoint": f"{SERVER_URL}/token",
        "response_types_supported": ["code"],
        "code_challenge_methods_supported": ["S256"],
    })


async def well_known_protected_resource(request: Request) -> JSONResponse:
    """RFC 9728 OAuth Protected Resource Metadata."""
    return JSONResponse({
        "resource": f"{SERVER_URL}/mcp",
        "authorization_servers": [SERVER_URL],
    })


async def authorize(request: Request) -> Response:
    """Start the authorization flow — validate params then redirect to GitHub."""
    params = request.query_params
    client_id = params.get("client_id", "")
    redirect_uri = params.get("redirect_uri", "")
    state = params.get("state", "")
    code_challenge = params.get("code_challenge", "")
    code_challenge_method = params.get("code_challenge_method", "")

    if not all([client_id, redirect_uri, state, code_challenge]):
        return JSONResponse(
            {"error": "invalid_request", "error_description": "Missing required parameters"},
            status_code=400,
        )

    if code_challenge_method and code_challenge_method != "S256":
        return JSONResponse(
            {"error": "invalid_request", "error_description": "Only S256 code_challenge_method is supported"},
            status_code=400,
        )

    # Generate a state value for the GitHub leg of the flow.
    github_state = secrets.token_urlsafe(32)

    _pending[github_state] = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "state": state,
        "code_challenge": code_challenge,
    }

    github_params = urlencode({
        "client_id": GITHUB_CLIENT_ID,
        "redirect_uri": f"{SERVER_URL}/callback",
        "state": github_state,
        "scope": "read:user",
    })
    return RedirectResponse(f"https://github.com/login/oauth/authorize?{github_params}")


async def callback(request: Request) -> Response:
    """Handle the redirect back from GitHub."""
    params = request.query_params
    code = params.get("code", "")
    github_state = params.get("state", "")

    pending = _pending.pop(github_state, None)
    if pending is None:
        return JSONResponse({"error": "invalid_state"}, status_code=400)

    # Exchange the GitHub code for an access token.
    async with httpx.AsyncClient() as client:
        token_resp = await client.post(
            "https://github.com/login/oauth/access_token",
            json={
                "client_id": GITHUB_CLIENT_ID,
                "client_secret": GITHUB_CLIENT_SECRET,
                "code": code,
            },
            headers={"Accept": "application/json"},
        )
        token_data = token_resp.json()

    gh_access_token = token_data.get("access_token")
    if not gh_access_token:
        return JSONResponse({"error": "github_token_exchange_failed"}, status_code=502)

    # Fetch the GitHub user profile.
    async with httpx.AsyncClient() as client:
        user_resp = await client.get(
            "https://api.github.com/user",
            headers={
                "Authorization": f"Bearer {gh_access_token}",
                "Accept": "application/json",
            },
        )
        user_data = user_resp.json()

    username = user_data.get("login", "")
    if username not in GITHUB_ALLOWED_USERS:
        return JSONResponse({"error": "access_denied", "error_description": "User not in allowlist"}, status_code=403)

    # Issue a short-lived authorization code.
    auth_code = secrets.token_urlsafe(48)
    _auth_codes[auth_code] = {
        "github_username": username,
        "code_challenge": pending["code_challenge"],
        "redirect_uri": pending["redirect_uri"],
        "client_id": pending["client_id"],
        "expires_at": time.time() + AUTH_CODE_TTL,
    }

    redirect_params = urlencode({"code": auth_code, "state": pending["state"]})
    return RedirectResponse(f"{pending['redirect_uri']}?{redirect_params}")


async def token(request: Request) -> JSONResponse:
    """Exchange an authorization code + PKCE verifier for a JWT bearer token."""
    body = await request.form()
    code = body.get("code", "")
    code_verifier = body.get("code_verifier", "")

    if not code or not code_verifier:
        return JSONResponse(
            {"error": "invalid_request", "error_description": "Missing code or code_verifier"},
            status_code=400,
        )

    entry = _auth_codes.pop(str(code), None)
    if entry is None:
        return JSONResponse({"error": "invalid_grant", "error_description": "Unknown or already-used code"}, status_code=400)

    if time.time() > entry["expires_at"]:
        return JSONResponse({"error": "invalid_grant", "error_description": "Authorization code expired"}, status_code=400)

    # Verify PKCE: S256 → base64url(sha256(code_verifier)) must equal code_challenge.
    digest = hashlib.sha256(str(code_verifier).encode("ascii")).digest()
    computed_challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")

    if computed_challenge != entry["code_challenge"]:
        return JSONResponse({"error": "invalid_grant", "error_description": "PKCE verification failed"}, status_code=400)

    now = time.time()
    access_token = jwt.encode(
        {
            "sub": entry["github_username"],
            "iat": int(now),
            "exp": int(now + BEARER_TOKEN_TTL),
        },
        MCP_JWT_SECRET,
        algorithm="HS256",
    )

    return JSONResponse({
        "access_token": access_token,
        "token_type": "bearer",
        "expires_in": BEARER_TOKEN_TTL,
    })


# ---------------------------------------------------------------------------
# Starlette routes
# ---------------------------------------------------------------------------

oauth_routes = [
    Route("/.well-known/oauth-authorization-server", well_known_metadata),
    Route("/.well-known/oauth-protected-resource", well_known_protected_resource),
    Route("/authorize", authorize),
    Route("/callback", callback),
    Route("/token", token, methods=["POST"]),
]
