"""MCP tool definitions for Open Brain."""

from __future__ import annotations

import json
from typing import Any

import os

import asyncpg
from mcp.server.fastmcp import FastMCP

import db

SERVER_URL = os.environ.get("SERVER_URL", "http://localhost:8000")


def create_mcp(pool_getter) -> FastMCP:
    """Create a FastMCP server with all tools registered.

    Args:
        pool_getter: A callable that returns the current asyncpg pool.
    """
    # Extract hostname from SERVER_URL for DNS rebinding protection.
    from urllib.parse import urlparse
    host = urlparse(SERVER_URL).hostname or "localhost"

    mcp = FastMCP(
        "open-brain",
        transport_security={
            "enable_dns_rebinding_protection": True,
            "allowed_hosts": [host],
        },
    )

    @mcp.tool()
    async def capture_thought(
        content: str,
        metadata: dict[str, Any] | None = None,
    ) -> str:
        """Capture a new thought.

        Args:
            content: The thought content text.
            metadata: Optional JSON metadata (type, topics, people, etc.).
        """
        pool = pool_getter()
        result = await db.capture_thought(pool, content, metadata)
        return json.dumps(result)

    @mcp.tool()
    async def search_thoughts(
        topic: str | None = None,
        person: str | None = None,
        type: str | None = None,
        keyword: str | None = None,
        limit: int = 20,
    ) -> str:
        """Search thoughts with optional filters.

        Args:
            topic: Filter by topic in metadata.
            person: Filter by person in metadata.
            type: Filter by thought type in metadata.
            keyword: Case-insensitive keyword search in content.
            limit: Maximum number of results (default 20).
        """
        pool = pool_getter()
        results = await db.search_thoughts(
            pool, topic=topic, person=person, type_=type, keyword=keyword, limit=limit,
        )
        return json.dumps(results)

    @mcp.tool()
    async def list_thoughts(
        type: str | None = None,
        topic: str | None = None,
        person: str | None = None,
        days: int | None = None,
        limit: int = 20,
    ) -> str:
        """List thoughts with optional filters including a time window.

        Args:
            type: Filter by thought type in metadata.
            topic: Filter by topic in metadata.
            person: Filter by person in metadata.
            days: Only include thoughts from the last N days.
            limit: Maximum number of results (default 20).
        """
        pool = pool_getter()
        results = await db.list_thoughts(
            pool, type_=type, topic=topic, person=person, days=days, limit=limit,
        )
        return json.dumps(results)

    @mcp.tool()
    async def thought_stats() -> str:
        """Get aggregate statistics about stored thoughts.

        Returns total count, type distribution, top 10 topics, and
        top 10 most frequently mentioned people.
        """
        pool = pool_getter()
        stats = await db.thought_stats(pool)
        return json.dumps(stats)

    return mcp
