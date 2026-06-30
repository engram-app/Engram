import os


def test_worker_has_unique_collection(qdrant_collection):
    """Each xdist worker must address its own Qdrant collection."""
    worker = os.environ.get("PYTEST_XDIST_WORKER", "gw0")
    assert qdrant_collection.endswith(f"_{worker}"), (
        f"collection {qdrant_collection!r} not scoped to worker {worker!r}"
    )
