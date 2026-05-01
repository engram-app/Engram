"""Test 50: Verify Qdrant 1024d prod-parity config and search pipeline.

API-only test. Creates a note to trigger collection creation and indexing,
verifies the collection has correct vector dimensions and binary quantization
config, then searches Qdrant directly with an Ollama-embedded vector.

Qdrant runs on SlowRaid (10.0.20.201, i9-14900K) which has AVX2 — required
for binary quantization's POPCNT/bitwise operations.
"""

import os
import time

import pytest
import requests

ENGRAM_API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://10.0.20.201:6333")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "ci_test_notes")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")


def _collection_info():
    resp = requests.get(
        f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}", timeout=10
    )
    resp.raise_for_status()
    return resp.json()["result"]


def _wait_for_collection(timeout=30):
    """Poll until the Qdrant collection exists (created on first indexing)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return _collection_info()
        except (requests.HTTPError, requests.ConnectionError, KeyError):
            time.sleep(2)
    raise TimeoutError(f"Collection {QDRANT_COLLECTION} not created within {timeout}s")


@pytest.fixture(scope="module")
def seeded_note(api_sync):
    """Create a note to trigger ensure_collection + indexing pipeline."""
    vaults = api_sync.list_vaults()
    assert vaults, "At least one vault must exist (created by api_only conftest)"
    vault_id = vaults[0]["id"]
    scoped = api_sync.with_vault(vault_id)

    ts = int(time.time())
    path = f"E2E/ProdParity/test50-{ts}.md"
    content = (
        f"# Qdrant Binary Quantization Parity\n\n"
        f"This note verifies the full embedding pipeline at 1024 dimensions.\n"
        f"Timestamp: {ts}\n"
    )
    note = scoped.create_note(path, content)
    assert note is not None, "Note creation should succeed"

    _wait_for_collection()

    return {"path": path, "api": scoped}


class TestQdrantConfig:
    """Verify Qdrant collection config matches prod dimensions."""

    def test_collection_exists(self, seeded_note):
        """The app should have created the collection after indexing."""
        info = _collection_info()
        assert info is not None, "Collection should exist"

    def test_vector_dimensions_1024(self, seeded_note):
        """Vectors should be 1024d to match Voyage prod config."""
        info = _collection_info()
        vectors = info["config"]["params"]["vectors"]
        assert vectors["size"] == 1024, (
            f"Expected 1024d vectors (prod parity), got {vectors['size']}d"
        )
        assert vectors["distance"] == "Cosine"

    def test_binary_quantization_enabled(self, seeded_note):
        """Binary quantization should be enabled with always_ram=true (prod parity)."""
        info = _collection_info()
        quant_config = info["config"].get("quantization_config", {})
        binary_config = quant_config.get("binary", {})
        assert binary_config.get("always_ram") is True, (
            f"Expected binary quantization with always_ram=true (prod parity), "
            f"got quantization_config={quant_config}"
        )


class TestSearchRoundTrip:
    """Verify the full note -> embed -> search pipeline."""

    @pytest.mark.flaky(reruns=0)
    def test_embed_and_search(self, seeded_note):
        """Full pipeline: wait for indexing, embed via Ollama, search Qdrant."""
        note_path = seeded_note["path"]

        # Step 1: Wait for THIS note to be indexed in Qdrant (not just any points).
        # Other api_only tests may index notes first, so poll by source_path filter.
        deadline = time.monotonic() + 60
        found = False
        while time.monotonic() < deadline:
            try:
                scroll_resp = requests.post(
                    f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/scroll",
                    json={
                        "filter": {
                            "must": [{"key": "source_path", "match": {"value": note_path}}]
                        },
                        "limit": 1,
                        "with_payload": True,
                    },
                    timeout=10,
                )
                if scroll_resp.status_code == 200:
                    pts = scroll_resp.json().get("result", {}).get("points", [])
                    if pts:
                        found = True
                        break
            except (requests.ConnectionError, requests.HTTPError):
                pass
            time.sleep(3)

        assert found, (
            f"Seeded note '{note_path}' was not indexed in Qdrant within 60s."
        )

        # Step 2: Embed query directly via Ollama
        embed_resp = requests.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": "mxbai-embed-large", "input": "embedding pipeline binary quantization parity"},
            timeout=60,
        )
        assert embed_resp.status_code == 200, (
            f"Ollama embed failed: HTTP {embed_resp.status_code} — {embed_resp.text[:200]}"
        )
        vector = embed_resp.json()["embeddings"][0]
        assert len(vector) == 1024, f"Expected 1024d vector, got {len(vector)}d"

        # Step 3: Search Qdrant directly with the embedded vector
        search_resp = requests.post(
            f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/query",
            json={
                "query": vector,
                "limit": 50,
                "with_payload": True,
            },
            timeout=10,
        )
        assert search_resp.status_code == 200, (
            f"Qdrant search failed: HTTP {search_resp.status_code} — {search_resp.text[:200]}"
        )

        result = search_resp.json().get("result", [])
        if isinstance(result, dict):
            result = result.get("points", [])

        paths = [r.get("payload", {}).get("source_path", "?") for r in result]
        assert any(note_path in p for p in paths), (
            f"Expected '{note_path}' in Qdrant results. "
            f"Got {len(result)} results with paths: {paths}"
        )


class TestSearchAPI:
    """Verify the Engram /api/search endpoint works end-to-end.

    Unlike TestSearchRoundTrip which hits Qdrant directly, this tests
    the full app path: query → Engram embed → Qdrant search → response.
    """

    @pytest.mark.flaky(reruns=0)
    def test_search_via_api(self, seeded_note):
        """POST /api/search should return results including the seeded note."""
        api = seeded_note["api"]
        note_path = seeded_note["path"]

        # Wait for the note to be indexed (reuse scroll check from earlier test)
        deadline = time.monotonic() + 60
        found = False
        while time.monotonic() < deadline:
            try:
                scroll_resp = requests.post(
                    f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/scroll",
                    json={
                        "filter": {
                            "must": [{"key": "source_path", "match": {"value": note_path}}]
                        },
                        "limit": 1,
                    },
                    timeout=10,
                )
                if scroll_resp.status_code == 200:
                    pts = scroll_resp.json().get("result", {}).get("points", [])
                    if pts:
                        found = True
                        break
            except (requests.ConnectionError, requests.HTTPError):
                pass
            time.sleep(3)

        assert found, f"Seeded note '{note_path}' not indexed within 60s"

        # Hit the Engram search API (not Qdrant directly)
        resp = api.session.post(
            f"{api.base_url}/search",
            json={"query": "embedding pipeline binary quantization", "limit": 20},
            timeout=30,
        )
        assert resp.status_code == 200, (
            f"POST /api/search failed: HTTP {resp.status_code} — {resp.text[:300]}"
        )

        results = resp.json().get("results", [])
        # /api/search now returns one row per note (not per chunk) with `path`
        # carrying the source path. The Qdrant scroll above still uses
        # `source_path` because that's the raw payload field name.
        paths = [r.get("path", "?") for r in results]
        assert any(note_path in p for p in paths), (
            f"Expected '{note_path}' in /api/search results. "
            f"Got {len(results)} results with paths: {paths}"
        )
