# Context Doc: WebSocket metrics (Prometheus)

_Last verified: 2026-10-08_

## Status
Working (introduced on `feat/websocket-prom-metrics`, PR engram-app/Engram#1914).

## What This Is
How WebSocket connection, frame and byte metrics reach Prometheus, and the traps hit building them.
Read this when adding or reading a WebSocket metric, or when a socket panel reads "No data".

## Where things live
- `lib/engram/prom_ex/web_socket.ex`: PromEx plugin (the thing that is actually scraped).
- `lib/engram_web/metered_serializer.ex`: `EngramWeb.MeteredSerializer`, emits `[:engram, :websocket, :frame]`.
- `lib/engram/telemetry/web_socket_poller.ex`: polls live connection counts.
- `lib/engram_web/endpoint.ex`: serializer list on both sockets.

## Gotchas

1. **`EngramWeb.Telemetry.metrics/0` is NOT Prometheus.** Metrics registered only there feed LiveDashboard. `engram.websocket.count` / `socket_bytes` existed there for months and never reached `/metrics`. Only PromEx plugins (`lib/engram/prom_ex/*.ex`, listed in `Engram.PromEx.plugins/0`) are scraped. A panel reading "No data" for a metric you can see in LiveDashboard means it was never added to a PromEx plugin.

2. **Phoenix encodes a broadcast ONCE per node per serializer.** `Phoenix.Channel.Server.dispatch/3` caches the encoded message by serializer, so counting `fastlane!/1` calls counts broadcasts, not deliveries. `MeteredSerializer` therefore counts local fastlane subscribers via `Registry.select` on `Engram.PubSub`, excluding subscribers that intercept the event (those push via `encode!/1` and are counted there). Known error: overcounts by 1 on `broadcast_from` (the sender is excluded from delivery but still in the Registry).

3. **`Phoenix.ChannelTest` bypasses the serializer.** Channel tests never exercise `MeteredSerializer`. Verify with a real client: start the endpoint with `server: true` on a spare port under `MIX_ENV=test` via `mix run --no-start script.exs`, then connect a Bun `WebSocket` to `/socket/device/websocket?vsn=2.0.0` and send a heartbeat (`[null,"1","phoenix","heartbeat",{}]`). No token or DB needed.

4. **Counting live connections by process label.** Socket transport processes carry the label `{Phoenix.Socket, handler, id}` (set in `Phoenix.Socket.__init__/1`); channel processes carry `{Phoenix.Channel, mod, topic}`. `:proc_lib.get_label/1` reads it cheaply, which is how the poller counts connections without tracking state.

5. **`last_value` gauges freeze.** When a series stops being emitted, Prometheus keeps exporting its last value forever. The poller emits `0` for every known prefix/socket each tick so a gauge drops instead of freezing at its final nonzero value.

6. **`topic_prefix` must be bounded.** Join replies echo client-chosen topics, so an unbounded prefix label is a cardinality bomb. Unknown prefixes map to `"other"`.

7. **Replacing the serializer list.** If you override `serializer:` on a socket, keep `{Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"}` alongside the 2.0 entry to match Phoenix's default negotiation, or vsn=1 clients fail to connect.

8. **Worktree test runs share `engram_test`.** Other worktrees use the same test DB at different migration states, producing `duplicate_object` errors. Set `MIX_TEST_PARTITION=_<name>` for an isolated DB.

## Failed Approaches / Dead Ends
- Counting frames in `fastlane!/1` alone (see gotcha 2): reports one frame per broadcast regardless of subscriber count.
- Testing serializer metrics with `Phoenix.ChannelTest` (see gotcha 3): passes without the serializer ever running.

## References
- PR engram-app/Engram#1914
- `deps/phoenix/lib/phoenix/channel/server.ex` (`dispatch/3`), `deps/phoenix/lib/phoenix/socket.ex` (`__init__/1`)
