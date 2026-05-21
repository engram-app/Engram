"""Backend REST API client for E2E tests."""

from __future__ import annotations

import logging
import re
import time
from urllib.parse import quote

import requests

logger = logging.getLogger(__name__)


class ApiClient:
    """Thin wrapper around the Engram REST API."""

    def __init__(self, base_url: str, auth):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        if isinstance(auth, str):
            self.session.headers["Authorization"] = f"Bearer {auth}"
        else:
            self.session.auth = auth

    @staticmethod
    def _log_error_response(resp: requests.Response) -> None:
        """Log non-2xx response details for post-mortem debugging."""
        if resp.status_code < 400:
            return
        body = resp.text[:500] if resp.text else "(empty)"
        logger.error(
            "%s %s → %d: %s",
            resp.request.method, resp.request.url, resp.status_code, body,
        )

    def _raise_for_status(self, resp: requests.Response) -> None:
        """Log error details, then raise."""
        self._log_error_response(resp)
        resp.raise_for_status()

    def ping(self) -> bool:
        """GET /folders — returns True if auth works."""
        resp = self.session.get(f"{self.base_url}/folders", timeout=10)
        return resp.status_code == 200

    def get_note(self, path: str) -> dict | None:
        """GET /notes/{path}. Returns parsed JSON or None on 404."""
        resp = self.session.get(
            f"{self.base_url}/notes/{quote(path, safe='')}", timeout=10
        )
        if resp.status_code == 404:
            return None
        self._raise_for_status(resp)
        return resp.json()

    def create_note(
        self, path: str, content: str, mtime: float | None = None
    ) -> dict:
        """POST /notes — upsert a note."""
        payload: dict = {
            "path": path,
            "content": content,
            "mtime": mtime if mtime is not None else time.time(),
        }
        resp = self.session.post(
            f"{self.base_url}/notes", json=payload, timeout=10
        )
        self._raise_for_status(resp)
        return resp.json()

    def delete_note(self, path: str) -> int:
        """DELETE /notes/{path}. Returns HTTP status code."""
        resp = self.session.delete(
            f"{self.base_url}/notes/{quote(path, safe='')}", timeout=10
        )
        return resp.status_code

    def get_changes(self, since: str) -> dict:
        """GET /notes/changes?since=..."""
        resp = self.session.get(
            f"{self.base_url}/notes/changes",
            params={"since": since},
            timeout=10,
        )
        self._raise_for_status(resp)
        return resp.json()

    def wait_for_note(
        self, path: str, timeout: float = 10, poll: float = 0.5
    ) -> dict:
        """Poll until note exists on server. Returns the note dict."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            note = self.get_note(path)
            if note is not None:
                return note
            time.sleep(poll)
        raise TimeoutError(f"Note {path} not on server after {timeout}s")

    def wait_for_note_content(
        self, path: str, expected: str, timeout: float = 10, poll: float = 0.5
    ) -> dict:
        """Poll until note on server contains expected substring."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            note = self.get_note(path)
            if note is not None and expected in note.get("content", ""):
                return note
            time.sleep(poll)
        raise TimeoutError(
            f"Note {path} did not contain '{expected}' on server after {timeout}s"
        )

    def wait_for_note_gone(
        self, path: str, timeout: float = 10, poll: float = 0.5
    ) -> None:
        """Poll until note returns 404 on server."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            note = self.get_note(path)
            if note is None:
                return
            time.sleep(poll)
        raise TimeoutError(f"Note {path} still on server after {timeout}s")

    def wait_for_attachment(
        self, path: str, timeout: float = 15, poll: float = 0.5
    ) -> None:
        """Poll until attachment is reachable on server (2xx)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.get_attachment(path).status_code == 200:
                return
            time.sleep(poll)
        raise TimeoutError(f"Attachment {path} not on server after {timeout}s")

    def wait_for_attachment_gone(
        self, path: str, timeout: float = 15, poll: float = 0.5
    ) -> None:
        """Poll until attachment returns 404 on server."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.get_attachment(path).status_code == 404:
                return
            time.sleep(poll)
        raise TimeoutError(f"Attachment {path} still on server after {timeout}s")

    def rename_note(self, old_path: str, new_path: str) -> int:
        """POST /notes/rename. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/notes/rename",
            json={"old_path": old_path, "new_path": new_path},
            timeout=10,
        )
        return resp.status_code

    def append_note(self, path: str, text: str) -> int:
        """POST /notes/append. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/notes/append",
            json={"path": path, "text": text},
            timeout=10,
        )
        return resp.status_code

    def upload_attachment(self, path: str, data: bytes, mime_type: str | None = None) -> int:
        """POST /attachments. Returns HTTP status code."""
        import base64
        payload = {
            "path": path,
            "content_base64": base64.b64encode(data).decode(),
            "mtime": time.time(),
        }
        if mime_type is not None:
            payload["mime_type"] = mime_type
        resp = self.session.post(
            f"{self.base_url}/attachments",
            json=payload,
            timeout=10,
        )
        return resp.status_code

    def get_attachment(self, path: str) -> requests.Response:
        """GET /attachments/{path}. Returns full response."""
        return self.session.get(
            f"{self.base_url}/attachments/{quote(path, safe='')}",
            timeout=10,
        )

    def delete_attachment(self, path: str) -> int:
        """DELETE /attachments/{path}. Returns HTTP status code."""
        resp = self.session.delete(
            f"{self.base_url}/attachments/{quote(path, safe='')}",
            timeout=10,
        )
        return resp.status_code

    def rename_folder(self, old_folder: str, new_folder: str) -> int:
        """POST /folders/rename. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/folders/rename",
            json={"old_folder": old_folder, "new_folder": new_folder},
            timeout=10,
        )
        return resp.status_code

    # -- Vault endpoints --------------------------------------------------

    def list_vaults(self) -> list[dict]:
        """GET /vaults. Returns list of vault dicts."""
        resp = self.session.get(f"{self.base_url}/vaults", timeout=10)
        self._raise_for_status(resp)
        return resp.json().get("vaults", [])

    def register_vault(self, name: str, client_id: str) -> tuple[dict, int]:
        """POST /vaults/register. Returns (response_json, status_code)."""
        resp = self.session.post(
            f"{self.base_url}/vaults/register",
            json={"name": name, "client_id": client_id},
            timeout=10,
        )
        self._log_error_response(resp)
        return resp.json() if resp.status_code in (200, 201) else {}, resp.status_code

    def create_vault(self, name: str) -> tuple[dict, int]:
        """POST /vaults. Returns (response_json, status_code)."""
        resp = self.session.post(
            f"{self.base_url}/vaults",
            json={"name": name},
            timeout=10,
        )
        self._log_error_response(resp)
        return resp.json() if resp.status_code in (200, 201) else {}, resp.status_code

    def get_vault(self, vault_id: int) -> tuple[dict | None, int]:
        """GET /vaults/:id. Returns (vault_dict or None, status_code)."""
        resp = self.session.get(f"{self.base_url}/vaults/{vault_id}", timeout=10)
        if resp.status_code == 404:
            return None, 404
        return resp.json(), resp.status_code

    def delete_vault(self, vault_id: int) -> int:
        """DELETE /vaults/:id. Returns HTTP status code."""
        resp = self.session.delete(f"{self.base_url}/vaults/{vault_id}", timeout=10)
        return resp.status_code

    def with_vault(self, vault_id: int) -> "ApiClient":
        """Return a new ApiClient that sends X-Vault-ID header on all requests."""
        clone = ApiClient.__new__(ApiClient)
        clone.base_url = self.base_url
        clone.session = requests.Session()
        clone.session.headers.update(self.session.headers)
        clone.session.headers["X-Vault-ID"] = str(vault_id)
        if self.session.auth is not None:
            clone.session.auth = self.session.auth
        return clone

    def mcp_call(self, tool_name: str, arguments: dict) -> tuple[dict, int]:
        """POST /mcp — JSON-RPC tools/call. Returns (response_json, status)."""
        resp = self.session.post(
            f"{self.base_url}/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            },
            timeout=10,
        )
        return resp.json(), resp.status_code

    def get_manifest(self) -> dict:
        """GET /sync/manifest. Returns manifest dict."""
        resp = self.session.get(f"{self.base_url}/sync/manifest", timeout=10)
        self._raise_for_status(resp)
        return resp.json()

    def ingest_logs(self, entries: list[dict]) -> int:
        """POST /logs. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/logs",
            json={"logs": entries},
            timeout=10,
        )
        return resp.status_code

    def get_logs(self, level: str = "", since: str = "", limit: int = 200) -> dict:
        """GET /logs. Returns logs dict."""
        params = {"limit": limit}
        if level:
            params["level"] = level
        if since:
            params["since"] = since
        resp = self.session.get(
            f"{self.base_url}/logs", params=params, timeout=10
        )
        self._raise_for_status(resp)
        return resp.json()

    def list_logs(
        self,
        limit: int = 200,
        level: str = "",
        since: str = "",
        query: str = "",
    ) -> list[dict]:
        """GET /logs and return the log entries as a flat list.

        Convenience wrapper around get_logs() for callers that want a list
        rather than the raw ``{"logs": [...]}`` envelope.

        ``query`` is a Python-side substring filter applied to the ``message``
        field — the backend /logs endpoint does not support full-text search
        (it accepts ``level``, ``category``, and ``since`` params only).
        """
        resp = self.get_logs(level=level, since=since, limit=limit)
        logs = resp.get("logs", [])
        if query:
            logs = [l for l in logs if query in l.get("message", "")]
        return logs

    def list_folder(self, folder: str = "") -> dict:
        """GET /folders/list. Returns folder listing dict."""
        resp = self.session.get(
            f"{self.base_url}/folders/list",
            params={"folder": folder},
            timeout=10,
        )
        self._raise_for_status(resp)
        return resp.json()

    def get_folders(self) -> list:
        """GET /folders."""
        resp = self.session.get(f"{self.base_url}/folders", timeout=10)
        self._raise_for_status(resp)
        return resp.json().get("folders", [])

    def search(self, query: str, folder: str | None = None) -> list[dict]:
        """POST /search. Returns list of result dicts with keys: path, title, folder, snippet, score."""
        body: dict = {"query": query}
        if folder:
            body["folder"] = folder
        resp = self.session.post(
            f"{self.base_url}/search", json=body, timeout=15
        )
        self._raise_for_status(resp)
        return resp.json().get("results", [])

