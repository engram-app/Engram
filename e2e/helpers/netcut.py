"""A per-device TCP relay between one Obsidian and the backend, with a cut switch.

The harness used to "go offline" by stubbing the plugin's REST methods
(`CdpClient.simulate_offline`). That leaves the WebSocket up and never touches
`requestUrl`, so it cannot reproduce the state a phone wakes into: a socket the
client still believes is OPEN while nothing reaches the server. The plugin's
REST calls go through Obsidian's `requestUrl` (main-process networking), so a
renderer-only CDP `Network.emulateNetworkConditions` misses them as well.

Pointing the device's `apiUrl` at this relay cuts BOTH at the transport,
outside the app, which is what a real network does:

    blackhole()  stop forwarding bytes; keep every socket open, accept new ones
                 and hold them silently. A half-open link: requests and
                 `crdt_doc_state` reads hang until their own timeouts.
    refuse()     close every socket and refuse new connections. Plain offline.
    restore()    close whatever is held (its framing is lost) and forward again,
                 so the client must reconnect, as after a real outage.

Runs its own event loop on a daemon thread, so it works from sync fixtures and
async tests alike.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from urllib.parse import urlsplit, urlunsplit

logger = logging.getLogger(__name__)

FORWARD, BLACKHOLE, REFUSE = "forward", "blackhole", "refuse"


class NetCut:
    def __init__(self, upstream_url: str) -> None:
        parts = urlsplit(upstream_url)
        self._upstream_parts = parts
        self._target = (parts.hostname or "127.0.0.1", parts.port or 80)
        self.mode = FORWARD
        self.port: int | None = None
        self._loop = asyncio.new_event_loop()
        self._server: asyncio.base_events.Server | None = None
        self._conns: set[asyncio.StreamWriter] = set()
        self._thread = threading.Thread(target=self._loop.run_forever, daemon=True)

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> "NetCut":
        self._thread.start()
        self._server = self._call(self._listen())
        self.port = self._server.sockets[0].getsockname()[1]
        logger.info("netcut :%d -> %s:%d", self.port, *self._target)
        return self

    def close(self) -> None:
        if self._server is not None:
            self._call(self._shutdown())
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=5)

    @property
    def url(self) -> str:
        """The upstream URL with host:port swapped for the relay's."""
        p = self._upstream_parts
        return urlunsplit((p.scheme, f"127.0.0.1:{self.port}", p.path, p.query, p.fragment))

    # -- switches ----------------------------------------------------------

    def blackhole(self) -> None:
        self._set(BLACKHOLE, drop=False)

    def refuse(self) -> None:
        self._set(REFUSE, drop=True)

    def restore(self) -> None:
        self._set(FORWARD, drop=True)

    def _set(self, mode: str, *, drop: bool) -> None:
        async def apply() -> int:
            self.mode = mode
            dropped = 0
            if drop:
                for w in list(self._conns):
                    w.transport.abort()
                    dropped += 1
                self._conns.clear()
            return dropped

        dropped = self._call(apply())
        logger.info("netcut :%s -> %s (dropped %d connections)", self.port, mode, dropped)

    # -- internals ---------------------------------------------------------

    def _call(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self._loop).result(timeout=10)

    async def _listen(self):
        return await asyncio.start_server(self._accept, "127.0.0.1", 0)

    async def _shutdown(self) -> None:
        self._server.close()
        for w in list(self._conns):
            w.transport.abort()
        self._conns.clear()

    async def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self.mode == REFUSE:
            writer.transport.abort()
            return
        self._conns.add(writer)
        try:
            up_reader, up_writer = await asyncio.open_connection(*self._target)
        except OSError:
            self._conns.discard(writer)
            writer.transport.abort()
            return
        self._conns.add(up_writer)
        try:
            await asyncio.gather(
                self._pump(reader, up_writer, writer),
                self._pump(up_reader, writer, up_writer),
            )
        finally:
            for w in (writer, up_writer):
                self._conns.discard(w)
                w.transport.abort()

    async def _pump(self, src, dst, own) -> None:
        """Copy src -> dst, dropping bytes while blackholed. `own` is the writer
        paired with `src`, so a closed peer is noticed from either side."""
        try:
            while data := await src.read(65536):
                if own.transport.is_closing():
                    return
                if self.mode == FORWARD:
                    dst.write(data)
                    await dst.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            dst.transport.abort()
