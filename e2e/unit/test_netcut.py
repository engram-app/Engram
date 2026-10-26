"""helpers.netcut cuts a device's link the way a real network does. Stack-free:
a local echo server stands in for the backend."""

from __future__ import annotations

import socket
import socketserver
import threading

import pytest

from helpers.netcut import NetCut


class _Echo(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        while data := self.request.recv(4096):
            self.request.sendall(data)


@pytest.fixture
def relay():
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Echo)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    cut = NetCut(f"http://127.0.0.1:{server.server_address[1]}/api").start()
    yield cut
    cut.close()
    server.shutdown()


def _connect(cut: NetCut) -> socket.socket:
    s = socket.create_connection(("127.0.0.1", cut.port), timeout=2)
    s.settimeout(1)
    return s


def _echoes(s: socket.socket, payload: bytes = b"ping") -> bool:
    s.sendall(payload)
    try:
        return s.recv(4096) == payload
    except TimeoutError:
        return False


def test_url_swaps_only_host_and_port(relay):
    assert relay.url == f"http://127.0.0.1:{relay.port}/api"


def test_blackhole_holds_the_socket_open_and_silent(relay):
    s = _connect(relay)
    assert _echoes(s)
    relay.blackhole()
    assert not _echoes(s), "blackhole must drop bytes, not forward them"
    # Still open: a half-dead link, not a closed one.
    s.settimeout(0.3)
    with pytest.raises(TimeoutError):
        s.recv(1)
    fresh = _connect(relay)
    assert not _echoes(fresh), "a connection made while blackholed is held too"


def test_refuse_closes_existing_and_new_connections(relay):
    s = _connect(relay)
    assert _echoes(s)
    relay.refuse()
    s.settimeout(1)
    assert s.recv(1) == b"", "existing socket must be closed"
    late = _connect(relay)
    late.settimeout(1)
    assert late.recv(1) == b"", "new connections are refused"


def test_restore_drops_held_sockets_and_forwards_new_ones(relay):
    s = _connect(relay)
    relay.blackhole()
    relay.restore()
    s.settimeout(1)
    assert s.recv(1) == b"", "held socket is dropped so the client reconnects"
    assert _echoes(_connect(relay))
