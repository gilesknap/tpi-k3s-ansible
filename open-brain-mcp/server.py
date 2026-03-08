"""Starlette ASGI application for the Open Brain MCP server."""

from __future__ import annotations

import os
from contextlib import asynccontextmanager

import jwt
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route
from starlette.types import ASGIApp, Receive, Scope, Send

import db
from oauth import oauth_routes
from tools import create_mcp

MCP_JWT_SECRET = os.environ.get("MCP_JWT_SECRET", "")


# ---------------------------------------------------------------------------
# JWT bearer-token middleware (applied only to /mcp)
# ---------------------------------------------------------------------------

class BearerTokenMiddleware:
    """ASGI middleware that validates a JWT Bearer token.

    Only enforced on paths starting with ``path_prefix`` (default ``/mcp``).
    All other requests pass through untouched.
    """

    def __init__(self, app: ASGIApp, path_prefix: str = "/mcp") -> None:
        self.app = app
        self.path_prefix = path_prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return

        path: str = scope.get("path", "")
        if not path.startswith(self.path_prefix):
            await self.app(scope, receive, send)
            return

        request = Request(scope)
        auth_header = request.headers.get("authorization", "")

        if not auth_header.startswith("Bearer "):
            response = JSONResponse(
                {"error": "missing_token", "error_description": "Authorization header with Bearer token required"},
                status_code=401,
            )
            await response(scope, receive, send)
            return

        token = auth_header[7:]
        try:
            jwt.decode(token, MCP_JWT_SECRET, algorithms=["HS256"])
        except jwt.ExpiredSignatureError:
            response = JSONResponse({"error": "token_expired"}, status_code=401)
            await response(scope, receive, send)
            return
        except jwt.InvalidTokenError:
            response = JSONResponse({"error": "invalid_token"}, status_code=401)
            await response(scope, receive, send)
            return

        await self.app(scope, receive, send)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

async def health(request: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------

def create_app() -> Starlette:
    """ASGI application factory used by uvicorn."""

    # Mutable holder so the pool can be set during lifespan startup.
    state: dict = {"pool": None}

    mcp_server = create_mcp(pool_getter=lambda: state["pool"])

    # FastMCP.streamable_http_app() returns a Starlette app with its own
    # route at /mcp.  We mount it at "/" so the final public path is /mcp.
    mcp_http_app = mcp_server.streamable_http_app()

    @asynccontextmanager
    async def lifespan(app: Starlette):
        database_url = os.environ.get("DATABASE_URL", "")
        if not database_url:
            raise RuntimeError("DATABASE_URL environment variable is required")
        state["pool"] = await db.create_pool(database_url)
        # The MCP session manager needs its task group started.
        # streamable_http_app() sets its own lifespan, but that inner
        # lifespan is not invoked when mounted inside another Starlette app.
        async with mcp_server.session_manager.run():
            try:
                yield
            finally:
                await state["pool"].close()

    routes = [
        Route("/health", health),
        *oauth_routes,
        # Mount the MCP sub-app at root; its internal route is /mcp.
        Mount("/", app=mcp_http_app, name="mcp"),
    ]

    app = Starlette(routes=routes, lifespan=lifespan)
    # Wrap the entire app with bearer-token middleware that only checks /mcp.
    return BearerTokenMiddleware(app, path_prefix="/mcp")
