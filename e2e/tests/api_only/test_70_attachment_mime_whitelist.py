"""Test 70: Pricing v2 §H — MIME / extension whitelist on attachment upload.

API-only. Verifies that the launch-day Phase 1 gate rejects executable
MIME types and dangerous extensions, while accepting legitimate file
formats.
"""

import pytest


@pytest.mark.asyncio
async def test_rejects_exe_extension_via_belt_and_braces(api_sync):
    """Client claims image/png but uploads a .exe — extension gate kicks."""
    status = api_sync.upload_attachment(
        "E2E/attachments/trojan.exe",
        b"MZ\x00\x00",  # PE header bytes, harmless inert
        mime_type="image/png",
    )
    assert status == 415, f"Expected 415 for .exe, got {status}"


@pytest.mark.asyncio
async def test_rejects_dosexec_mime(api_sync):
    """Explicit application/x-dosexec MIME is rejected even with safe extension."""
    status = api_sync.upload_attachment(
        "E2E/attachments/installer",
        b"\x00" * 64,
        mime_type="application/x-dosexec",
    )
    assert status == 415, f"Expected 415 for x-dosexec, got {status}"


@pytest.mark.asyncio
async def test_rejects_octet_stream_default(api_sync):
    """Unknown extension → detected as octet-stream → rejected."""
    status = api_sync.upload_attachment(
        "E2E/attachments/mystery.xyz",
        b"opaque",
    )
    assert status == 415, f"Expected 415 for unknown .xyz, got {status}"


@pytest.mark.asyncio
async def test_accepts_pdf(api_sync):
    """Legitimate PDF passes the whitelist."""
    # Minimal valid PDF header — enough to satisfy size + MIME, not parsed
    pdf_bytes = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n1 0 obj\n<<>>\nendobj\n%%EOF\n"
    status = api_sync.upload_attachment(
        "E2E/attachments/doc70.pdf",
        pdf_bytes,
    )
    assert status in (200, 201), f"Expected 2xx for .pdf, got {status}"
