"""MCP tool definitions for Open Brain."""

from __future__ import annotations

import base64
import json
from typing import Any

import os

from mcp.server.fastmcp import FastMCP

import db

SERVER_URL = os.environ.get("SERVER_URL", "http://localhost:8000")
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")


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
        """Capture a new thought as text with optional structured metadata.

        Content should be self-contained — understandable without the
        original conversation context. For images or binary content shared
        in conversation, describe the content as text rather than uploading.

        Args:
            content: The thought content text.
            metadata: Optional JSON metadata. Always include "type". Extract
                "topics", "people", and "action_items" when present.

                type: decision | person_note | idea | task | meeting |
                    reference | article_summary
                topics: list of lowercase hyphenated slugs, e.g.
                    ["k3s-cluster", "dashboard-redesign"]
                people: list of names mentioned
                action_items: list of tasks with owners/deadlines if known
        """
        pool = pool_getter()
        result = await db.capture_thought(pool, content, metadata)
        return json.dumps(result)

    @mcp.tool()
    async def get_attachment(
        thought_id: str,
        filename: str,
    ) -> str:
        """Retrieve a file attachment from a thought.

        Returns the file content as base64 with its MIME type, so Claude
        can display images or read PDFs directly.

        Args:
            thought_id: UUID of the thought that owns the attachment.
            filename: Name of the attached file.
        """
        if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
            return json.dumps({"error": "Supabase storage is not configured"})

        try:
            content_bytes, mime_type = await db.download_attachment(
                thought_id,
                filename,
                SUPABASE_URL,
                SUPABASE_SERVICE_KEY,
            )
            return json.dumps(
                {
                    "filename": filename,
                    "mime_type": mime_type,
                    "content_base64": base64.b64encode(content_bytes).decode("ascii"),
                }
            )
        except Exception as exc:  # noqa: BLE001
            return json.dumps({"error": str(exc)})

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
            pool,
            topic=topic,
            person=person,
            type_=type,
            keyword=keyword,
            limit=limit,
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
            pool,
            type_=type,
            topic=topic,
            person=person,
            days=days,
            limit=limit,
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
