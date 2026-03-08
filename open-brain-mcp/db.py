"""Database access layer for the thoughts table."""

from __future__ import annotations

import json
from collections import Counter
from typing import Any

import asyncpg
import httpx


async def create_pool(database_url: str) -> asyncpg.Pool:
    """Create and return an asyncpg connection pool."""
    return await asyncpg.create_pool(database_url)


# ---------------------------------------------------------------------------
# capture_thought
# ---------------------------------------------------------------------------

async def capture_thought(
    pool: asyncpg.Pool,
    content: str,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Insert a new thought and return the created row."""
    row = await pool.fetchrow(
        """
        INSERT INTO thoughts (content, metadata)
        VALUES ($1, $2::jsonb)
        RETURNING id, content, metadata, created_at
        """,
        content,
        json.dumps(metadata) if metadata else "{}",
    )
    return _row_to_dict(row)


# ---------------------------------------------------------------------------
# search_thoughts
# ---------------------------------------------------------------------------

async def search_thoughts(
    pool: asyncpg.Pool,
    *,
    topic: str | None = None,
    person: str | None = None,
    type_: str | None = None,
    keyword: str | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """Search thoughts with optional filters."""
    clauses: list[str] = []
    params: list[Any] = []
    idx = 1

    if topic:
        clauses.append(f"metadata->'topics' @> ${idx}::jsonb")
        params.append(json.dumps([topic]))
        idx += 1

    if person:
        clauses.append(f"metadata->'people' @> ${idx}::jsonb")
        params.append(json.dumps([person]))
        idx += 1

    if type_:
        clauses.append(f"metadata->>'type' = ${idx}")
        params.append(type_)
        idx += 1

    if keyword:
        clauses.append(f"content ILIKE ${idx}")
        params.append(f"%{keyword}%")
        idx += 1

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    params.append(limit)

    query = f"""
        SELECT id, content, metadata, created_at
        FROM thoughts
        {where}
        ORDER BY created_at DESC
        LIMIT ${idx}
    """
    rows = await pool.fetch(query, *params)
    return [_row_to_dict(r) for r in rows]


# ---------------------------------------------------------------------------
# list_thoughts
# ---------------------------------------------------------------------------

async def list_thoughts(
    pool: asyncpg.Pool,
    *,
    type_: str | None = None,
    topic: str | None = None,
    person: str | None = None,
    days: int | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """List thoughts with optional filters including a time window."""
    clauses: list[str] = []
    params: list[Any] = []
    idx = 1

    if type_:
        clauses.append(f"metadata->>'type' = ${idx}")
        params.append(type_)
        idx += 1

    if topic:
        clauses.append(f"metadata->'topics' @> ${idx}::jsonb")
        params.append(json.dumps([topic]))
        idx += 1

    if person:
        clauses.append(f"metadata->'people' @> ${idx}::jsonb")
        params.append(json.dumps([person]))
        idx += 1

    if days is not None:
        clauses.append(f"created_at >= now() - make_interval(days => ${idx})")
        params.append(days)
        idx += 1

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    params.append(limit)

    query = f"""
        SELECT id, content, metadata, created_at
        FROM thoughts
        {where}
        ORDER BY created_at DESC
        LIMIT ${idx}
    """
    rows = await pool.fetch(query, *params)
    return [_row_to_dict(r) for r in rows]


# ---------------------------------------------------------------------------
# thought_stats
# ---------------------------------------------------------------------------

async def thought_stats(pool: asyncpg.Pool) -> dict[str, Any]:
    """Aggregate statistics across all thoughts."""
    total = await pool.fetchval("SELECT count(*) FROM thoughts")

    rows = await pool.fetch(
        """
        SELECT metadata
        FROM thoughts
        ORDER BY created_at DESC
        LIMIT 100
        """
    )

    type_counter: Counter[str] = Counter()
    topic_counter: Counter[str] = Counter()
    people_counter: Counter[str] = Counter()

    for row in rows:
        meta = json.loads(row["metadata"]) if row["metadata"] else {}
        if t := meta.get("type"):
            type_counter[t] += 1
        for topic in meta.get("topics", []):
            topic_counter[topic] += 1
        for person in meta.get("people", []):
            people_counter[person] += 1

    return {
        "total_thoughts": total,
        "type_distribution": dict(type_counter),
        "top_topics": dict(topic_counter.most_common(10)),
        "frequent_people": dict(people_counter.most_common(10)),
    }


# ---------------------------------------------------------------------------
# attachment storage
# ---------------------------------------------------------------------------

async def download_attachment(
    thought_id: str,
    filename: str,
    storage_url: str,
    service_key: str,
) -> tuple[bytes, str]:
    """Download a file from Supabase Storage.

    Args:
        thought_id: UUID of the parent thought.
        filename: Name of the stored file.
        storage_url: Supabase Kong gateway URL.
        service_key: Supabase service-role key for auth.

    Returns:
        Tuple of (file_bytes, mime_type).
    """
    path = f"{thought_id}/{filename}"
    url = f"{storage_url}/storage/v1/object/brain-attachments/{path}"

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            url,
            headers={"Authorization": f"Bearer {service_key}"},
        )
        resp.raise_for_status()

    mime_type = resp.headers.get("content-type", "application/octet-stream")
    return resp.content, mime_type


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _row_to_dict(row: asyncpg.Record) -> dict[str, Any]:
    """Convert an asyncpg Record to a plain dict with JSON-safe values."""
    d = dict(row)
    if "metadata" in d and isinstance(d["metadata"], str):
        d["metadata"] = json.loads(d["metadata"])
    if "created_at" in d:
        d["created_at"] = d["created_at"].isoformat()
    if "id" in d:
        d["id"] = str(d["id"])
    return d
