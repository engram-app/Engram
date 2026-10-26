"""Release-gauntlet fixtures: a private two-device pair whose network the test owns.

Each `gauntlet` pair gets:
  * its OWN user and vault, so whole-folder assertions measure only this test
    (docs/context/e2e-session-vault-scoping-trap.md);
  * a NetCut relay per device (helpers/netcut.py), so a test can cut one
    device's link at the transport, half-open or refused;
  * free choice of plugin build per device, so an upgrade test can boot the
    previous RELEASE and swap the candidate in.

Displays: the e2e-crdt job owns six (DISPLAY_BASE..DISPLAY_BASE-5). Session
devices A/B/C take the top three; the pair takes the next two. Serial only.
"""

from __future__ import annotations

import logging
import os
import secrets
from dataclasses import dataclass
from pathlib import Path

import pytest

import conftest as harness
from helpers.api import ApiClient
from helpers.billing import grant_test_plan
from helpers.cdp import CdpClient
from helpers.clerk import e2e_email
from helpers.netcut import NetCut
from helpers.obsidian import ObsidianInstance

logger = logging.getLogger(__name__)


@dataclass
class Device:
    name: str
    inst: ObsidianInstance
    net: NetCut

    @property
    def cdp(self) -> CdpClient:
        return self.inst.cdp

    @property
    def vault(self) -> Path:
        return self.inst.vault_path


@dataclass
class Pair:
    api: ApiClient
    a: Device
    b: Device | None

    @property
    def devices(self) -> list[Device]:
        return [d for d in (self.a, self.b) if d is not None]

    @property
    def vaults(self) -> dict[str, Path]:
        return {d.name: d.vault for d in self.devices}


@pytest.fixture
def gauntlet(ts, auth_provider):
    """Factory: `pair = gauntlet("g1", plugin_a=..., with_b=True)`.

    Instances are built but only started when `start=True` (the default), so
    an upgrade test can seed a vault on disk or pick a build first.
    """
    if os.environ.get("PYTEST_XDIST_WORKER_COUNT", "1") != "1":
        pytest.skip("gauntlet pairs use fixed displays; run serially")
    made: list[tuple[str, Pair]] = []

    def make(label: str, *, plugin_a: Path | None = None, plugin_b: Path | None = None,
             with_b: bool = True, start: bool = True) -> Pair:
        email = e2e_email(label, ts)
        user_id, api_key = auth_provider.provision_user(email, secrets.token_urlsafe(32))
        grant_test_plan(email)
        client_id = f"e2e-gauntlet-{label}-{ts}"
        api = ApiClient(harness.API_URL, api_key)
        _, status = api.register_vault(f"gauntlet-{label}", client_id)
        assert status in (200, 201), f"register_vault -> {status}"

        def device(name: str, offset: int, src: Path | None) -> Device:
            net = NetCut(harness.API_URL).start()
            inst = ObsidianInstance(
                name=name,
                vault_path=Path(f"{harness.VAULT_PREFIX}-{name.lower()}"),
                display=f":{harness.DISPLAY_BASE - offset}",
                api_url=net.url,
                api_key=api_key,
                plugin_src=src or harness.PLUGIN_SRC,
                obsidian_bin=harness.OBSIDIAN_BIN,
                client_id=client_id,
                config_dir=Path(f"{harness.CONFIG_PREFIX}-{name.lower()}"),
            )
            return Device(name, inst, net)

        pair = Pair(
            api=api,
            a=device("GA", 3, plugin_a),
            b=device("GB", 4, plugin_b) if with_b else None,
        )
        made.append((user_id, pair))
        if start:
            for d in pair.devices:
                d.inst.start()
        return pair

    yield make

    for user_id, pair in made:
        for d in pair.devices:
            try:
                d.inst.stop()
            finally:
                d.net.close()
        try:
            auth_provider.cleanup_user(user_id)
        except Exception as e:  # noqa: BLE001 - teardown must not mask the test result
            logger.warning("gauntlet user cleanup failed: %s", e)
