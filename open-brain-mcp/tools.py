"""MCP tool definitions for Open Brain."""

from __future__ import annotations

import base64
import json
from typing import Any

import os

import asyncpg
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

    @mcp.prompt()
    def capture_guide() -> str:
        """How to capture thoughts with good metadata."""
        return """When the user asks you to save, remember, or capture something,
use capture_thought with well-structured metadata extracted from their message.

## Content guidelines

- Content should be self-contained — understandable without the conversation.
- For images, PDFs, or other binary content the user shares in conversation,
  describe the content as text. File uploads go through a separate channel.

## Metadata schema

Always include a "type" field. Extract "topics", "people", and "action_items"
when present. All fields except "type" are optional.

    {
        "type": "decision | person_note | idea | task | meeting | reference | article_summary",
        "topics": ["project-name", "theme", ...],
        "people": ["Alice", "Bob", ...],
        "action_items": ["Send spec by Thursday", ...]
    }

## Type selection guide

- **decision** — a choice that was made, with context and owner.
- **person_note** — something learned about a person (role, preferences, life events).
- **idea** / **insight** — a realisation or concept worth keeping.
- **task** — something that needs doing, with owner if known.
- **meeting** — debrief with attendees, key points, and action items.
- **reference** — factual information worth filing (configs, procedures, specs).
- **article_summary** — key takeaways from an article, talk, or podcast.

## Topic conventions

- Use lowercase, hyphenated slugs: "k3s-cluster", "open-brain", "cloudflare".
- Be specific: "dashboard-redesign" not "project".
- Reuse existing topics where possible (check with search_thoughts first for
  large batches, but not needed for single captures).

## Examples

User: "Remember that we decided to move the launch to March 15 because QA
found three blockers. Rachel owns it."

    capture_thought(
        content="Decision: Moving the launch to March 15. Context: QA found three blockers in the payment flow. Owner: Rachel.",
        metadata={"type": "decision", "topics": ["launch"], "people": ["Rachel"], "action_items": ["Rachel to resolve QA blockers before March 15"]}
    )

User: "Marcus mentioned he wants to move to the platform team"

    capture_thought(
        content="Marcus — mentioned he wants to move to the platform team. Feeling overwhelmed since the reorg.",
        metadata={"type": "person_note", "topics": ["reorg", "platform-team"], "people": ["Marcus"]}
    )
"""

    @mcp.tool()
    async def capture_thought(
        content: str,
        metadata: dict[str, Any] | None = None,
    ) -> str:
        """Capture a new thought as text with optional structured metadata.

        For file attachments, upload directly to Supabase Storage via the
        local CLI or Slack bot — binary data should not pass through the
        MCP context window.

        Args:
            content: The thought content text.
            metadata: Optional JSON metadata (type, topics, people, etc.).
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
                thought_id, filename, SUPABASE_URL, SUPABASE_SERVICE_KEY,
            )
            return json.dumps({
                "filename": filename,
                "mime_type": mime_type,
                "content_base64": base64.b64encode(content_bytes).decode("ascii"),
            })
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
