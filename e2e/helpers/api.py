"""Backend REST API client for E2E tests."""

from __future__ import annotations

import logging
import time
import uuid
from urllib.parse import quote

import requests

from helpers.latency import DELIVERY_TIMEOUT, MCP_TIMEOUT, SEARCH_TIMEOUT

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

    def batch_delete_notes(self, ids: list[str]) -> int:
        """POST /notes/batch-delete with note IDs (from the manifest). Returns
        status. The endpoint enforces X-Idempotency-Key (any fresh UUID)."""
        resp = self.session.post(
            f"{self.base_url}/notes/batch-delete",
            json={"ids": ids},
            headers={"X-Idempotency-Key": str(uuid.uuid4())},
            timeout=30,
        )
        return resp.status_code

    def wait_for_note(
        self, path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.5
    ) -> dict:
        """Poll until note exists on server. Returns the note dict.

        Shares the central delivery budget (helpers.latency): the timeout is a
        true-breakage bound, not a latency assert.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            note = self.get_note(path)
            if note is not None:
                return note
            time.sleep(poll)
        raise TimeoutError(f"Note {path} not on server after {timeout}s")

    def wait_for_note_content(
        self, path: str, expected: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.5
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
        self, path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.5
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
        self, path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.5
    ) -> None:
        """Poll until attachment is reachable on server (2xx)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.get_attachment(path).status_code == 200:
                return
            time.sleep(poll)
        raise TimeoutError(f"Attachment {path} not on server after {timeout}s")

    def wait_for_attachment_gone(
        self, path: str, timeout: float = DELIVERY_TIMEOUT, poll: float = 0.5
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

    def rename_attachment(self, old_path: str, new_path: str) -> int:
        """POST /attachments/rename (web-origin move). Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/attachments/rename",
            json={"old_path": old_path, "new_path": new_path},
            timeout=10,
        )
        return resp.status_code

    def get_backlinks(self, note_id: str) -> list[dict]:
        """GET /notes/by-id/{id}/backlinks. Returns the backlink edge list.

        Edges are written by the async indexing pipeline (EmbedNote →
        commit_index → Links.replace_links), so callers polling this are
        waiting on the embed pipeline, not the note upsert.
        """
        resp = self.session.get(
            f"{self.base_url}/notes/by-id/{note_id}/backlinks", timeout=10
        )
        self._raise_for_status(resp)
        return resp.json().get("backlinks", [])

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
            json={"old_path": old_folder, "new_path": new_folder},
            timeout=10,
        )
        return resp.status_code

    def create_folder(self, folder: str) -> int:
        """POST /folders — create an explicit empty-folder marker. Returns status."""
        resp = self.session.post(
            f"{self.base_url}/folders",
            json={"folder": folder},
            timeout=10,
        )
        return resp.status_code

    def delete_folder(self, folder: str) -> int:
        """DELETE /folders/*path — delete a folder marker. Returns status.

        The route is a path splat, so slashes stay literal (safe='/'); only
        spaces / reserved chars in each segment are percent-encoded.
        """
        resp = self.session.delete(
            f"{self.base_url}/folders/{quote(folder, safe='/')}", timeout=10
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

    # `create_vault` (POST /vaults) is gone — it made a new vault per call, so a
    # retry produced a duplicate. Use `register_vault` with a stable client_id.

    def get_vault(self, vault_id: str) -> tuple[dict | None, int]:
        """GET /vaults/:id. Returns (vault_dict or None, status_code)."""
        resp = self.session.get(f"{self.base_url}/vaults/{vault_id}", timeout=10)
        if resp.status_code == 404:
            return None, 404
        return resp.json(), resp.status_code

    def delete_vault(self, vault_id: str) -> int:
        """DELETE /vaults/:id. Returns HTTP status code."""
        resp = self.session.delete(f"{self.base_url}/vaults/{vault_id}", timeout=10)
        return resp.status_code

    def with_vault(self, vault_id: str) -> "ApiClient":
        """Return a new ApiClient that sends X-Vault-ID header on all requests."""
        clone = ApiClient.__new__(ApiClient)
        clone.base_url = self.base_url
        clone.session = requests.Session()
        clone.session.headers.update(self.session.headers)
        clone.session.headers["X-Vault-ID"] = str(vault_id)
        if self.session.auth is not None:
            clone.session.auth = self.session.auth
        return clone

    # MCP tools that reach Engram.Search and therefore pay a query embed. This is
    # NOT just the obvious one — verified against lib/engram/mcp/handlers.ex:
    #   search_notes    → Search.search (handlers.ex:67/72)
    #   suggest_folder  → Search.search (handlers.ex:165)
    #   create_note     → auto_place_folder → Search.search (handlers.ex:252/669),
    #                     but only when no `suggested_folder` arg is supplied
    # Everything else (get_note, write_note, list_folders, …) is a cheap
    # DB/Qdrant round-trip and belongs on the generic delivery bound.
    #
    # The two budgets are NOT equal (SEARCH_TIMEOUT 60s vs MCP_TIMEOUT 30s), so a
    # missing entry here is a real wrong timeout, not a latent one — an embedding
    # tool left off this list gets half the budget it needs.
    _EMBEDDING_MCP_TOOLS = frozenset({"search_notes", "suggest_folder", "create_note"})

    def mcp_call(self, tool_name: str, arguments: dict) -> tuple[dict, int]:
        """POST /mcp — JSON-RPC tools/call. Returns (response_json, status)."""
        timeout = SEARCH_TIMEOUT if tool_name in self._EMBEDDING_MCP_TOOLS else MCP_TIMEOUT
        resp = self.session.post(
            f"{self.base_url}/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            },
            timeout=timeout,
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

    def search(
        self,
        query: str,
        folder: str | None = None,
        tags: list[str] | None = None,
        limit: int | None = None,
    ) -> list[dict]:
        """POST /search. Returns list of result dicts with keys: path, title, folder, snippet, score.

        `tags`/`limit` exist so test-local search helpers don't hand-roll their
        own `session.post` — every /search call must share ONE timeout budget
        (see SEARCH_TIMEOUT), and a hand-rolled call site silently opts out of it.
        `folder=""` is a real filter (the vault root), so test against None.
        """
        body: dict = {"query": query}
        if folder is not None:
            body["folder"] = folder
        if tags is not None:
            body["tags"] = tags
        if limit is not None:
            body["limit"] = limit
        resp = self.session.post(f"{self.base_url}/search", json=body, timeout=SEARCH_TIMEOUT)
        self._raise_for_status(resp)
        return resp.json().get("results", [])

