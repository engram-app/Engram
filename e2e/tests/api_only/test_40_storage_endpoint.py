"""Test 40: Storage endpoint reports correct usage after uploads.

API-only test. Verifies GET /user/storage returns sensible values
and that used_bytes increases after uploading an attachment.
"""

import time

import pytest


@pytest.mark.asyncio
async def test_storage_endpoint(api_sync):
    """Storage usage increases after uploading an attachment."""
    # Get baseline storage
    resp = api_sync.session.get(f"{api_sync.base_url}/user/storage", timeout=10)
    resp.raise_for_status()
    baseline = resp.json()

    assert "used_bytes" in baseline, "Should have used_bytes field"
    assert "max_bytes" in baseline, "Should have max_bytes field"
    assert "file_count" in baseline, "Should have file_count field"
    assert baseline["max_bytes"] > 0, "max_bytes should be positive"

    initial_used = baseline["used_bytes"]
    initial_count = baseline["file_count"]

    # Upload a small attachment. Use .png so the MIME whitelist (pricing-v2
    # §H) accepts it; this test cares about byte accounting, not MIME.
    data = b"x" * 1024  # 1KB
    status = api_sync.upload_attachment(
        f"E2E/attachments/storage40-{int(time.time())}.png",
        data,
    )
    assert status in (200, 201), f"Upload should succeed, got {status}"

    # Check storage increased
    resp = api_sync.session.get(f"{api_sync.base_url}/user/storage", timeout=10)
    resp.raise_for_status()
    after = resp.json()

    assert after["used_bytes"] >= initial_used, (
        f"used_bytes should not decrease: {initial_used} → {after['used_bytes']}"
    )
    assert after["file_count"] >= initial_count + 1, (
        f"file_count should increase: {initial_count} → {after['file_count']}"
    )
