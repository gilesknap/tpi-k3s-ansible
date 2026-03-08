"""Local stdio MCP server for Open Brain.

Wraps the Supabase REST API and Storage API so Claude Code can capture
thoughts, search, and upload/download file attachments without the
context-window limitations of the remote MCP server.

Environment variables:
    BRAIN_API_URL   — Supabase API base URL (e.g. https://supabase-api.example.com)
    BRAIN_API_KEY   — x-brain-key shared secret
    BRAIN_SERVICE_KEY — Supabase service-role JWT (for Storage API)
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

API_URL = os.environ.get("BRAIN_API_URL", "")
API_KEY = os.environ.get("BRAIN_API_KEY", "")
SERVICE_KEY = os.environ.get("BRAIN_SERVICE_KEY", "")

FUNC_URL = f"{API_URL}/functions/v1/open-brain-mcp"
STORAGE_URL = f"{API_URL}/storage/v1"

mcp = FastMCP("open-brain-cli")


def _headers() -> dict[str, str]:
    """Common headers for Edge Function calls."""
    return {
        "x-brain-key": API_KEY,
        "Content-Type": "application/json",
    }


def _storage_headers(content_type: str = "application/octet-stream") -> dict[str, str]:
    """Headers for Supabase Storage API calls."""
    return {
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": content_type,
    }


# ---------------------------------------------------------------------------
# Thought tools (via Edge Function REST API)
# ---------------------------------------------------------------------------


@mcp.tool()
async def capture_thought(
    content: str,
    metadata: dict[str, Any] | None = None,
) -> str:
    """Capture a new thought with optional metadata.

    Args:
        content: The thought content text.
        metadata: Optional metadata dict with fields like type, topics,
            people, action_items, source.
    """
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{FUNC_URL}/capture",
            headers=_headers(),
            json={"content": content, "metadata": metadata or {}},
        )
        resp.raise_for_status()
    return json.dumps(resp.json())


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
    body: dict[str, Any] = {"limit": limit}
    if topic:
        body["topic"] = topic
    if person:
        body["person"] = person
    if type:
        body["type"] = type
    if keyword:
        body["keyword"] = keyword

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{FUNC_URL}/search",
            headers=_headers(),
            json=body,
        )
        resp.raise_for_status()
    return json.dumps(resp.json())


@mcp.tool()
async def list_thoughts(
    type: str | None = None,
    topic: str | None = None,
    person: str | None = None,
    days: int | None = None,
    limit: int = 20,
) -> str:
    """List recent thoughts with optional filters.

    Args:
        type: Filter by thought type in metadata.
        topic: Filter by topic in metadata.
        person: Filter by person in metadata.
        days: Only include thoughts from the last N days.
        limit: Maximum number of results (default 20).
    """
    body: dict[str, Any] = {"limit": limit}
    if type:
        body["type"] = type
    if topic:
        body["topic"] = topic
    if person:
        body["person"] = person
    if days is not None:
        body["days"] = days

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{FUNC_URL}/list",
            headers=_headers(),
            json=body,
        )
        resp.raise_for_status()
    return json.dumps(resp.json())


@mcp.tool()
async def thought_stats() -> str:
    """Get aggregate statistics about stored thoughts."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{FUNC_URL}/stats",
            headers=_headers(),
        )
        resp.raise_for_status()
    return json.dumps(resp.json())


# ---------------------------------------------------------------------------
# Attachment tools (via Supabase Storage API — binary, no context window)
# ---------------------------------------------------------------------------


@mcp.tool()
async def upload_attachment(
    thought_id: str,
    file_path: str,
) -> str:
    """Upload a local file as an attachment to a thought.

    The file is read from disk and uploaded directly to object storage.
    No base64 encoding through the context window.

    Args:
        thought_id: UUID of the thought to attach the file to.
        file_path: Absolute path to the local file to upload.
    """
    path = Path(file_path)
    if not path.is_file():
        return json.dumps({"error": f"File not found: {file_path}"})

    # Guess MIME type from extension.
    mime_types = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".gif": "image/gif",
        ".webp": "image/webp",
        ".pdf": "application/pdf",
        ".txt": "text/plain",
        ".md": "text/markdown",
    }
    mime_type = mime_types.get(path.suffix.lower(), "application/octet-stream")

    content_bytes = path.read_bytes()
    storage_path = f"{thought_id}/{path.name}"
    url = f"{STORAGE_URL}/object/brain-attachments/{storage_path}"

    async with httpx.AsyncClient() as client:
        resp = await client.put(
            url,
            content=content_bytes,
            headers=_storage_headers(mime_type),
        )
        resp.raise_for_status()

    # Update the thought's metadata with the attachment reference.
    async with httpx.AsyncClient() as client:
        # Fetch current metadata.
        get_resp = await client.post(
            f"{FUNC_URL}/search",
            headers=_headers(),
            json={"keyword": thought_id, "limit": 1},
        )
        thoughts = get_resp.json().get("thoughts", [])
        current_meta = thoughts[0].get("metadata", {}) if thoughts else {}

        attachments = current_meta.get("attachments", [])
        attachments.append({
            "filename": path.name,
            "path": storage_path,
            "mime_type": mime_type,
        })
        current_meta["attachments"] = attachments

        # Update via REST — use PostgREST directly.
        patch_resp = await client.patch(
            f"{API_URL}/rest/v1/thoughts?id=eq.{thought_id}",
            headers={
                "apikey": SERVICE_KEY,
                "Authorization": f"Bearer {SERVICE_KEY}",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
            json={"metadata": current_meta},
        )
        patch_resp.raise_for_status()

    return json.dumps({
        "uploaded": storage_path,
        "mime_type": mime_type,
        "size_bytes": len(content_bytes),
    })


@mcp.tool()
async def download_attachment(
    thought_id: str,
    filename: str,
) -> str:
    """Download a thought's attachment to a local temp file.

    Returns the local file path so Claude Code can read/display it.

    Args:
        thought_id: UUID of the thought that owns the attachment.
        filename: Name of the attached file.
    """
    storage_path = f"{thought_id}/{filename}"
    url = f"{STORAGE_URL}/object/brain-attachments/{storage_path}"

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            url,
            headers={"Authorization": f"Bearer {SERVICE_KEY}"},
        )
        resp.raise_for_status()

    # Save to a temp file that persists after the call.
    suffix = Path(filename).suffix
    tmp = tempfile.NamedTemporaryFile(
        prefix="brain-",
        suffix=suffix,
        delete=False,
    )
    tmp.write(resp.content)
    tmp.close()

    return json.dumps({
        "local_path": tmp.name,
        "filename": filename,
        "size_bytes": len(resp.content),
        "mime_type": resp.headers.get("content-type", "application/octet-stream"),
    })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main():
    """Run the stdio MCP server."""
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
