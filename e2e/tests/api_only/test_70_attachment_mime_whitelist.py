"""Test 70: executable-extension blocklist on attachment upload.

API-only. Verifies that executable extensions are refused (415) and every
other file type is accepted.
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
async def test_accepts_zip(api_sync):
    """Archives are not executables; they sync."""
    status = api_sync.upload_attachment(
        "E2E/attachments/archive70.zip",
        b"PK\x03\x04",
        mime_type="application/zip",
    )
    assert status in (200, 201), f"Expected 2xx for .zip, got {status}"


@pytest.mark.asyncio
async def test_accepts_unknown_extension(api_sync):
    """Unknown extension -> octet-stream -> accepted (only executables are blocked)."""
    status = api_sync.upload_attachment(
        "E2E/attachments/mystery70.xyz",
        b"opaque",
    )
    assert status in (200, 201), f"Expected 2xx for unknown .xyz, got {status}"


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
