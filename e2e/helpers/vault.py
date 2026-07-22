"""Vault file operations for E2E tests.

Wait helpers share the central delivery budget (``helpers.latency``): the
timeout is a true-breakage bound, not a latency assert — each successful wait
records its elapsed time to the per-run latency report instead.
"""

from __future__ import annotations

import time
from pathlib import Path

from helpers.latency import DELIVERY_TIMEOUT, record


def write_note(vault_path: Path, rel_path: str, content: str) -> None:
    """Write a markdown file to the vault, creating parent dirs as needed."""
    full = vault_path / rel_path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content, encoding="utf-8")


def write_binary(vault_path: Path, rel_path: str, data: bytes) -> None:
    """Write a binary file (attachment) to the vault, creating parent dirs."""
    full = vault_path / rel_path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_bytes(data)


def read_note(vault_path: Path, rel_path: str) -> str:
    """Read file content. Raises FileNotFoundError if missing."""
    return (vault_path / rel_path).read_text(encoding="utf-8")


def delete_note(vault_path: Path, rel_path: str) -> None:
    """Delete a file from the vault."""
    full = vault_path / rel_path
    full.unlink(missing_ok=True)


def wait_for_file(
    vault_path: Path, rel_path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.3
) -> str:
    """Poll until file exists and is non-empty, return content. Raise TimeoutError.

    The non-empty guard mirrors wait_for_binary: sync materializes a note by
    creating the file, then writing its body, so a bare exists() check can
    catch the 0-byte window and return "" — the read-before-flush race behind
    intermittent `assert "x" in ""` failures. No delivery test waits for a
    genuinely-empty note (test_27 uses read_note), so requiring content is safe.
    """
    full = vault_path / rel_path
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if full.exists() and full.stat().st_size > 0:
            record("file", rel_path, time.monotonic() - start)
            return full.read_text(encoding="utf-8")
        time.sleep(poll)
    raise TimeoutError(f"File {rel_path} did not appear within {timeout}s")


def wait_for_binary(
    vault_path: Path, rel_path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.3
) -> bytes:
    """Poll until binary file exists, return bytes. Raise TimeoutError."""
    full = vault_path / rel_path
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if full.exists() and full.stat().st_size > 0:
            record("binary", rel_path, time.monotonic() - start)
            return full.read_bytes()
        time.sleep(poll)
    raise TimeoutError(f"Binary file {rel_path} did not appear within {timeout}s")


def wait_for_file_gone(
    vault_path: Path, rel_path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.3
) -> None:
    """Poll until file no longer exists. Raise TimeoutError."""
    full = vault_path / rel_path
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if not full.exists():
            record("file_gone", rel_path, time.monotonic() - start)
            return
        time.sleep(poll)
    raise TimeoutError(f"File {rel_path} still exists after {timeout}s")


def wait_for_folder(
    vault_path: Path, rel_path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.3
) -> None:
    """Poll until an (empty) folder directory materializes in the vault.

    Empty-folder markers are not in the cursor feed; the plugin materializes
    them via the folders.batch resync, so this shares the delivery budget.
    Raise TimeoutError.
    """
    full = vault_path / rel_path
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if full.is_dir():
            record("folder", rel_path, time.monotonic() - start)
            return
        time.sleep(poll)
    raise TimeoutError(f"Folder {rel_path} did not appear within {timeout}s")


def wait_for_folder_gone(
    vault_path: Path, rel_path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.3
) -> None:
    """Poll until a folder directory is removed from the vault. Raise TimeoutError."""
    full = vault_path / rel_path
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if not full.exists():
            record("folder_gone", rel_path, time.monotonic() - start)
            return
        time.sleep(poll)
    raise TimeoutError(f"Folder {rel_path} still exists after {timeout}s")


def wait_for_content(
    vault_path: Path,
    rel_path: str,
    expected: str,
    timeout: float = DELIVERY_TIMEOUT,
    poll: float = 0.3,
) -> str:
    """Poll until file contains expected substring, return full content."""
    full = vault_path / rel_path
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if full.exists():
            content = full.read_text(encoding="utf-8")
            if expected in content:
                record("content", rel_path, time.monotonic() - start)
                return content
        time.sleep(poll)
    raise TimeoutError(
        f"File {rel_path} did not contain '{expected}' within {timeout}s"
    )


def wait_for_exact_content(
    vault_path: Path,
    rel_path: str,
    expected: str,
    timeout: float = DELIVERY_TIMEOUT,
    poll: float = 0.3,
) -> str:
    """Poll until file content equals expected exactly, return it.

    Substring checks pass even when sync truncates, duplicates, or reorders
    body lines; exact equality is the only assertion that proves the full
    payload survived the round trip.
    """
    full = vault_path / rel_path
    last: str | None = None
    start = time.monotonic()
    deadline = start + timeout
    while time.monotonic() < deadline:
        if full.exists():
            last = full.read_text(encoding="utf-8")
            if last == expected:
                record("exact_content", rel_path, time.monotonic() - start)
                return last
        time.sleep(poll)
    raise TimeoutError(
        f"File {rel_path} never exactly matched expected content within {timeout}s\n"
        f"--- expected ---\n{expected!r}\n--- last seen ---\n{last!r}"
    )


def list_notes(vault_path: Path, folder: str = "") -> list[str]:
    """List .md files in folder (relative paths)."""
    search = vault_path / folder if folder else vault_path
    if not search.exists():
        return []
    return sorted(
        str(p.relative_to(vault_path))
        for p in search.rglob("*.md")
        if ".obsidian" not in p.parts and ".trash" not in p.parts
    )
