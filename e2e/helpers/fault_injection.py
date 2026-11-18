"""Inject transport faults into a running Obsidian plugin over CDP.

Two seams, both on objects the plugin itself holds, so the plugin's REAL error
handling runs against a fault it cannot tell from a server's:

  * `EngramApi.sendRequest` (`syncEngine.api`): every REST call funnels through
    `request()` -> `sendRequest()`. `requestUrl` is an ES-module import and
    cannot be wrapped from a page, so the fault is thrown from here in the exact
    shape `throwIfHttpError` produces (`{status, headers, text}`), which is what
    `statusOf`, `retryAfterMs` and `categorizeError` read.
  * `NoteChannel.send` (`noteStream`): rewrites the `crdt:` `phx_join` frame's
    `crdt_proto`, so the REAL backend refuses the join with `crdt_proto_too_old`
    and the plugin's real `onCrdtJoinError` path runs.

Every fault keeps an oracle that cannot lie: a hit log recorded INSIDE the
wrapper (time, method, path, folder, faulted?). A test asserts the wrapper fired
before it trusts any "nothing happened" assertion. The wrapper is always
restorable: callers use the context managers, whose `finally` unwraps.
"""

from __future__ import annotations

import json
import re
from contextlib import asynccontextmanager

from helpers.cdp import ENGINE_PATH, PLUGIN_PATH

_API = f"{ENGINE_PATH}.api"
_STREAM = f"{PLUGIN_PATH}.noteStream"

_API_DISARM_JS = f"""
(() => {{
  const api = {_API}, f = api.__e2eFault;
  if (!f) return false;
  if (f.hadOwn) api.sendRequest = f.orig; else delete api.sendRequest;
  delete api.__e2eFault;
  return true;
}})()
"""


async def disarm_api_fault(cdp) -> bool:
    """Unwrap `sendRequest`. True if a wrapper was installed."""
    return await cdp.evaluate(_API_DISARM_JS) is True


async def arm_api_fault(
    cdp,
    method: str,
    path_regex: str,
    status: int,
    *,
    retry_after_s: int | None = None,
    times: int | None = None,
) -> None:
    """Fail matching REST calls with `status`. `times=None` fails every match;
    `times=N` fails the first N and lets later ones through (still logged)."""
    re.compile(path_regex)  # fail in Python, not as an opaque JS SyntaxError
    headers = {} if retry_after_s is None else {"retry-after": str(retry_after_s)}
    await disarm_api_fault(cdp)
    armed = await cdp.evaluate(
        f"""
(() => {{
  const api = {_API};
  if (!api || typeof api.sendRequest !== 'function') return 'no api.sendRequest';
  const f = {{
    hadOwn: Object.prototype.hasOwnProperty.call(api, 'sendRequest'),
    orig: api.sendRequest,
    remaining: {json.dumps(times)},
    hits: [],
  }};
  const re = new RegExp({json.dumps(path_regex)});
  api.__e2eFault = f;
  api.sendRequest = function (m, p, body, ...rest) {{
    const match = m === {json.dumps(method)} && re.test(p);
    const fail = match && (f.remaining === null || f.remaining > 0);
    if (match) {{
      if (fail && f.remaining !== null) f.remaining -= 1;
      f.hits.push({{ t: Date.now(), path: p, folder: body && body.folder, faulted: fail }});
    }}
    if (!fail) return f.orig.call(this, m, p, body, ...rest);
    return Promise.reject(Object.assign(new Error('Request failed, status {status}'),
      {{ status: {status}, headers: {json.dumps(headers)}, text: '' }}));
  }};
  return 'armed';
}})()
"""
    )
    assert armed == "armed", f"api fault did not arm: {armed!r}"


async def release_api_fault(cdp) -> None:
    """Stop failing, keep logging: later matches pass through and are still counted."""
    await cdp.evaluate(f"(() => {{ {_API}.__e2eFault.remaining = 0; return true; }})()")


async def read_api_fault(cdp) -> list[dict]:
    """Every matching call since arming: `{t (ms), path, folder, faulted}`."""
    raw = await cdp.evaluate(f"JSON.stringify({_API}.__e2eFault?.hits ?? null)")
    hits = json.loads(raw)
    assert hits is not None, "api fault is not armed (wrapper lost, e.g. the api was rebuilt)"
    return hits


@asynccontextmanager
async def api_fault(cdp, method, path_regex, status, **kw):
    """Arm for the block; ALWAYS unwrap, even when the body raises."""
    await arm_api_fault(cdp, method, path_regex, status, **kw)
    try:
        yield
    finally:
        await disarm_api_fault(cdp)


@asynccontextmanager
async def crdt_join_downgrade(cdp):
    """Make every `crdt:` join this device sends claim `crdt_proto: 1`, so the
    real backend answers `crdt_proto_too_old`. Yields a reader for how many
    joins were rewritten. ALWAYS unwraps."""
    armed = await cdp.evaluate(
        f"""
(() => {{
  const s = {_STREAM};
  if (!s || typeof s.send !== 'function') return 'no noteStream.send';
  if (s.__e2eJoin) return 'already armed';
  const j = s.__e2eJoin = {{ hadOwn: Object.prototype.hasOwnProperty.call(s, 'send'),
                            orig: s.send, rewritten: 0 }};
  s.send = function (frame, ...rest) {{
    if (Array.isArray(frame) && frame[3] === 'phx_join'
        && String(frame[2]).startsWith('crdt:') && frame[4]) {{
      frame[4].crdt_proto = 1; j.rewritten += 1;
    }}
    return j.orig.call(this, frame, ...rest);
  }};
  return 'armed';
}})()
"""
    )
    assert armed == "armed", f"crdt join downgrade did not arm: {armed!r}"

    async def rewritten() -> int:
        return await cdp.evaluate(f"{_STREAM}.__e2eJoin?.rewritten ?? 0")

    try:
        yield rewritten
    finally:
        await cdp.evaluate(
            f"""
(() => {{
  const s = {_STREAM}, j = s.__e2eJoin;
  if (!j) return false;
  if (j.hadOwn) s.send = j.orig; else delete s.send;
  delete s.__e2eJoin;
  return true;
}})()
"""
        )
