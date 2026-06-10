"""Test 75: Contract — backend accepts client-supplied UUIDv7 on note create.

PG18 + UUIDv7 PK rework Phase I (I2). The sync contract is that the
Obsidian plugin (or any caller) mints a UUIDv7 client-side and pushes
it to /api/notes; the server persists the supplied id as the row's PK.

This unlocks:
  * Offline-first push without a "blank id placeholder" round-trip
  * Idempotent retries (client uses the same id on resend)
  * Easy de-dup at the merge layer (server doesn't have to invent ids)

The Note changeset already casts :id (see lib/engram/notes/note.ex);
this test exercises the end-to-end controller -> context -> insert path.
"""

import os
import secrets
import time
import uuid

import pytest

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"


def _mint_uuidv7() -> str:
    """Mint a UUIDv7 string.

    Prefers stdlib ``uuid.uuid7`` (Python 3.14+); falls back to a
    spec-compliant hand-rolled version for 3.12/3.13 CI runners.
    Reference: RFC 9562 §5.7.
    """
    if hasattr(uuid, "uuid7"):
        return str(uuid.uuid7())

    # Hand-rolled fallback. 48-bit unix-ms timestamp, 4-bit version (7),
    # 12 bits random_a, 2-bit variant (10), 62 bits random_b.
    ms = int(time.time() * 1000) & ((1 << 48) - 1)
    rand_a = secrets.randbits(12)
    rand_b = secrets.randbits(62)

    hi = (ms << 16) | (0x7 << 12) | rand_a
    lo = (0b10 << 62) | rand_b
    raw = (hi << 64) | lo
    return str(uuid.UUID(int=raw))


class TestClientMintNoteId:
    """Server persists the client-supplied note id as the row PK."""

    def test_create_with_client_minted_id_round_trips(self, api_sync):
        """POST /notes with explicit ``id`` -> server returns same id; GET round-trips."""
        client_id = _mint_uuidv7()
        path = f"client-mint-{client_id[:8]}.md"
        content = "# client-minted\n\nbackend should honor my id"

        # api_sync.create_note() doesn't expose id in its payload (it's the
        # idiomatic create path), so we POST directly with the explicit id
        # to verify the controller forwards it.
        resp = api_sync.session.post(
            f"{API_URL}/notes",
            json={
                "id": client_id,
                "path": path,
                "content": content,
                "mtime": time.time(),
            },
            timeout=10,
        )
        assert resp.status_code == 200, (
            f"Expected 200, got {resp.status_code}: {resp.text}"
        )

        body = resp.json()
        returned_id = body.get("note", {}).get("id") or body.get("id")
        assert returned_id == client_id, (
            f"Backend did not honor client-minted id. "
            f"Sent {client_id!r}, server returned {returned_id!r}. "
            f"Phase B follow-up: Notes.upsert_note must read attrs['id'] "
            f"instead of unconditionally calling mint_id/0."
        )

        # Round-trip: GET /notes/:path should return the same id.
        fetched = api_sync.get_note(path)
        assert fetched is not None, f"Note {path} not found after POST"
        assert fetched["id"] == client_id, (
            f"Round-trip id mismatch: GET returned {fetched['id']!r}, "
            f"expected {client_id!r}"
        )
        assert fetched.get("content") == content

    def test_client_minted_id_must_be_valid_uuid(self, api_sync):
        """Non-uuid ``id`` in POST body is rejected (changeset validation)."""
        path = f"bad-id-{secrets.token_hex(4)}.md"
        resp = api_sync.session.post(
            f"{API_URL}/notes",
            json={
                "id": "not-a-uuid",
                "path": path,
                "content": "garbage id",
                "mtime": time.time(),
            },
            timeout=10,
        )
        # Either 422 (changeset validation rejects malformed uuid) or the
        # server silently ignores invalid id and mints its own — either is
        # acceptable, but the row must not end up with the literal string.
        # If 422, validate; if 200, ensure server-minted id != "not-a-uuid".
        if resp.status_code == 200:
            body = resp.json()
            returned_id = body.get("note", {}).get("id") or body.get("id")
            assert returned_id != "not-a-uuid", (
                "Server accepted a malformed string as PK"
            )
        else:
            assert resp.status_code in (400, 422), (
                f"Expected 200/422 for bad uuid, got {resp.status_code}: {resp.text}"
            )
