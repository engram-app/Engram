# Vault-channel Fan-out Pacer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a large-vault genesis fan-out burst from starving concurrent live-edit frames on the per-vault `sync:` topic (engram-app/Engram#1002).

**Architecture:** A new `Engram.Notes.FanoutPacer` classifies each `note_yjs_update` by per-note recency (via a public ETS table, at the call site). Hot notes (recently active = live editing) emit immediately; cold notes (bulk enrollment) enqueue into a per-vault queue drained at a bounded rate by a single named GenServer. The two existing emit sites call `FanoutPacer.emit/4` instead of `Broadcast.emit/3`.

**Tech Stack:** Elixir/Phoenix, `Phoenix.PubSub` (via `Engram.Sync.Broadcast` → `EngramWeb.Endpoint.broadcast`), ETS, GenServer, ExUnit (`Engram.DataCase`).

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-07-13-vault-channel-fanout-pacer-design.md`.

## Global Constraints

- **Backend-only, ONE PR**, in the worktree `.worktrees/fix-fanout-throttle` on branch `fix/vault-channel-fanout-throttle` (off `origin/main`).
- **No `mix.exs` version bump** (backend versions ship via release-v* git tags, never per-PR bumps).
- **Signed commits required** (org ruleset): every commit uses `git commit -S`.
- **Conventional commits** (`feat:` / `fix:` / `test:`), subject < 50 chars.
- **Before push:** `mix format`, `mix credo --strict`, `mix sobelow`, `mix dialyzer`, and the FULL `mix test` must pass (pre-push gates run format+credo+sobelow; dialyzer + full suite are on you).
- Config reads use `Application.get_env(:engram, key, default)` evaluated **at call time** (like `Engram.Notes.CheckpointGate.limit/0`), so tests can `put_env` per-test.
- Do NOT touch `crdt_channel.ex` topic-auth. Do NOT change the per-note CRDT room relay.

---

### Task 1: `FanoutPacer` skeleton — config, supervision, ETS, disabled passthrough

**Files:**
- Create: `lib/engram/notes/fanout_pacer.ex`
- Modify: `lib/engram/application.ex` (add child to the supervision tree, next to `Engram.Notes.CheckpointGate`)
- Modify: `config/test.exs` (default pacing OFF in tests)
- Test: `test/engram/notes/fanout_pacer_test.exs`

**Interfaces:**
- Produces:
  - `Engram.Notes.FanoutPacer.emit(topic :: String.t(), event :: String.t(), payload :: map(), note_id :: String.t()) :: :ok`
  - `Engram.Notes.FanoutPacer.reset() :: :ok` (test helper: clears queues + ETS)
  - Config readers (private): `pacing_enabled?/0`, `hot_window_ms/0`, `drain_batch/0`, `drain_interval_ms/0`

- [ ] **Step 1: Write the failing test**

Create `test/engram/notes/fanout_pacer_test.exs`:

```elixir
defmodule Engram.Notes.FanoutPacerTest do
  # async: false — shares the named FanoutPacer process + global ETS + app env.
  use ExUnit.Case, async: false

  alias Engram.Notes.FanoutPacer

  setup do
    prev = Application.get_all_env(:engram)
    on_exit(fn ->
      Application.put_env(:engram, :fanout_pacing_enabled, prev[:fanout_pacing_enabled])
      Application.put_env(:engram, :fanout_hot_window_ms, prev[:fanout_hot_window_ms])
      Application.put_env(:engram, :fanout_drain_batch, prev[:fanout_drain_batch])
      Application.put_env(:engram, :fanout_drain_interval_ms, prev[:fanout_drain_interval_ms])
    end)

    FanoutPacer.reset()
    :ok
  end

  defp payload(note_id), do: %{"note_id" => note_id, "b64" => "x", "head" => "h"}

  test "when pacing disabled, emit/4 broadcasts inline immediately" do
    Application.put_env(:engram, :fanout_pacing_enabled, false)
    topic = "sync:u1:v1"
    EngramWeb.Endpoint.subscribe(topic)

    FanoutPacer.emit(topic, "note_yjs_update", payload("n1"), "n1")

    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_yjs_update",
      payload: %{"note_id" => "n1"}
    }, 200
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd .worktrees/fix-fanout-throttle && mix test test/engram/notes/fanout_pacer_test.exs`
Expected: FAIL — `module Engram.Notes.FanoutPacer is not available` (or `function reset/0 undefined`).

- [ ] **Step 3: Write minimal implementation**

Create `lib/engram/notes/fanout_pacer.ex`:

```elixir
defmodule Engram.Notes.FanoutPacer do
  @moduledoc """
  Paces the per-vault CRDT fan-out (`note_yjs_update`) so a large-vault genesis
  burst cannot starve a concurrent live-edit frame on the single `sync:` topic
  (engram-app/Engram#1002).

  Both emit sites (`CrdtPersistence.update_v1/4` delta, `CrdtDeliver.fanout_idle/3`
  full-state) call `emit/4` instead of `Broadcast.emit/3`. Classification is by
  per-note recency, done at the CALL SITE via a public ETS table so the live-edit
  hot path never enters this GenServer:

    * HOT  — the note had a fan-out within `hot_window_ms` (someone is actively
             editing it) → broadcast immediately, bypassing the pacer.
    * COLD — first touch / stale (bulk enrollment) → enqueued and drained per-vault
             at a bounded rate, room-free and never dropped.

  ponytail: single pacer process + one ETS table. Shard by vault (a Registry of
  per-vault pacers) only if fan-out throughput on one node ever measurably
  saturates this process; at launch scale one process is ample.
  """
  use GenServer

  alias Engram.Sync.Broadcast

  @table :fanout_hot

  @default_pacing_enabled true
  @default_hot_window_ms 2_000
  @default_drain_batch 20
  @default_drain_interval_ms 100

  # Client -----------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Fan out `event`/`payload` on `topic` for `note_id`, paced when enabled.

  HOT (recent) notes broadcast inline; COLD notes are enqueued for paced drain.
  When pacing is disabled, always broadcasts inline (test/rollback path).
  """
  @spec emit(String.t(), String.t(), map(), String.t()) :: :ok
  def emit(topic, event, payload, note_id) do
    if pacing_enabled?() and cold?(note_id) do
      GenServer.cast(__MODULE__, {:enqueue, topic, event, payload})
    else
      Broadcast.emit(topic, event, payload)
    end

    :ok
  end

  @doc "Test helper: drop all queues and clear the hot table."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # Marks `note_id` seen now and returns whether it was COLD (not seen within the
  # hot window). Benign lookup/insert race across concurrent emits for one note
  # only ever mis-classifies a frame hot-vs-cold, never loses or corrupts it.
  defp cold?(note_id) do
    now = System.monotonic_time(:millisecond)

    cold =
      case :ets.lookup(@table, note_id) do
        [{^note_id, last}] -> now - last >= hot_window_ms()
        [] -> true
      end

    :ets.insert(@table, {note_id, now})
    cold
  end

  # Server -----------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{queues: %{}, draining: false}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | queues: %{}, draining: false}}
  end

  # Config readers (evaluated at call time so tests can put_env) ------------

  defp pacing_enabled?,
    do: Application.get_env(:engram, :fanout_pacing_enabled, @default_pacing_enabled) == true

  defp hot_window_ms, do: pos_env(:fanout_hot_window_ms, @default_hot_window_ms)
  defp drain_batch, do: pos_env(:fanout_drain_batch, @default_drain_batch)
  defp drain_interval_ms, do: pos_env(:fanout_drain_interval_ms, @default_drain_interval_ms)

  defp pos_env(key, default) do
    case Application.get_env(:engram, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end
end
```

Add to `lib/engram/application.ex` children, immediately after `Engram.Notes.CheckpointGate,`:

```elixir
        Engram.Notes.CheckpointGate,
        Engram.Notes.FanoutPacer,
```

Add to `config/test.exs`, near the `:checkpoint_inline_limit` line:

```elixir
# Pacing OFF by default in tests so fan-out delivery stays synchronous and
# existing broadcast/e2e timing assertions are unaffected. The pacer's own
# test flips it on per-test.
config :engram, :fanout_pacing_enabled, false
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/notes/fanout_pacer_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/fanout_pacer.ex lib/engram/application.ex config/test.exs test/engram/notes/fanout_pacer_test.exs
git commit -S -m "feat(crdt): FanoutPacer skeleton + disabled passthrough"
```

---

### Task 2: Cold enqueue + paced per-vault drain

**Files:**
- Modify: `lib/engram/notes/fanout_pacer.ex`
- Test: `test/engram/notes/fanout_pacer_test.exs`

**Interfaces:**
- Consumes: `FanoutPacer.emit/4`, `reset/0` (Task 1)
- Produces: `handle_cast({:enqueue, topic, event, payload}, state)`, `handle_info(:drain, state)`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/notes/fanout_pacer_test.exs`:

```elixir
  test "cold flood drains in batches over ticks, not all at once" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 3)
    Application.put_env(:engram, :fanout_drain_interval_ms, 50)

    topic = "sync:u2:v2"
    EngramWeb.Endpoint.subscribe(topic)

    # 7 distinct COLD notes (each note_id touched once → all cold).
    for i <- 1..7, do: FanoutPacer.emit(topic, "note_yjs_update", payload("c#{i}"), "c#{i}")

    # First tick delivers exactly drain_batch (3), then no more until next tick.
    for _ <- 1..3, do: assert_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
    refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 20

    # Remaining 4 drain over the following ticks.
    for _ <- 1..4, do: assert_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 300
    refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 100
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/fanout_pacer_test.exs -k "cold flood"`
Expected: FAIL — the frames are never received (no `handle_cast`/`handle_info`; cast is silently dropped by the skeleton).

- [ ] **Step 3: Write minimal implementation**

Add these clauses to `lib/engram/notes/fanout_pacer.ex` (after `handle_call(:reset, ...)`):

```elixir
  @impl true
  def handle_cast({:enqueue, topic, event, payload}, %{queues: queues} = state) do
    q = Map.get(queues, topic, :queue.new())
    queues = Map.put(queues, topic, :queue.in({event, payload}, q))
    {:noreply, ensure_draining(%{state | queues: queues})}
  end

  @impl true
  def handle_info(:drain, state) do
    queues =
      state.queues
      |> Enum.map(fn {topic, q} -> {topic, drain_topic(topic, q, drain_batch())} end)
      |> Enum.reject(fn {_topic, q} -> :queue.is_empty(q) end)
      |> Map.new()

    if map_size(queues) > 0 do
      Process.send_after(self(), :drain, drain_interval_ms())
      {:noreply, %{state | queues: queues, draining: true}}
    else
      {:noreply, %{state | queues: %{}, draining: false}}
    end
  end

  # Pop up to `n` frames off `q` and broadcast each on `topic` (per-vault FIFO).
  defp drain_topic(topic, q, n) when n > 0 do
    case :queue.out(q) do
      {{:value, {event, payload}}, q2} ->
        Broadcast.emit(topic, event, payload)
        drain_topic(topic, q2, n - 1)

      {:empty, q2} ->
        q2
    end
  end

  defp drain_topic(_topic, q, _n), do: q

  # Arm the drain timer exactly once; subsequent enqueues ride the running loop.
  defp ensure_draining(%{draining: true} = state), do: state

  defp ensure_draining(state) do
    Process.send_after(self(), :drain, drain_interval_ms())
    %{state | draining: true}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/notes/fanout_pacer_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/fanout_pacer.ex test/engram/notes/fanout_pacer_test.exs
git commit -S -m "feat(crdt): paced per-vault cold-frame drain"
```

---

### Task 3: Hot bypass, per-vault fairness, ETS sweep

**Files:**
- Modify: `lib/engram/notes/fanout_pacer.ex`
- Test: `test/engram/notes/fanout_pacer_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1–2
- Produces: `handle_info(:sweep, state)` (stale-ETS prune); no signature changes to `emit/4`

- [ ] **Step 1: Write the failing tests**

Add to `test/engram/notes/fanout_pacer_test.exs`:

```elixir
  test "hot frame bypasses and arrives before the bulk of a concurrent cold flood (#1002)" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 1)
    Application.put_env(:engram, :fanout_drain_interval_ms, 80)

    topic = "sync:u3:v3"
    EngramWeb.Endpoint.subscribe(topic)

    # Warm note "live" so it is HOT (seen within the window). This first frame is
    # cold (paced), so drain it before asserting the bypass on the SECOND frame.
    FanoutPacer.emit(topic, "note_yjs_update", payload("live"), "live")
    assert_receive %Phoenix.Socket.Broadcast{payload: %{"note_id" => "live"}}, 300

    # A big genesis flood of distinct COLD notes.
    for i <- 1..20, do: FanoutPacer.emit(topic, "note_yjs_update", payload("g#{i}"), "g#{i}")

    # The live note edits again → HOT → must arrive immediately, not behind the 20.
    FanoutPacer.emit(topic, "note_yjs_update", payload("live"), "live")
    assert_receive %Phoenix.Socket.Broadcast{payload: %{"note_id" => "live"}}, 60
  end

  test "two topics drain independently (per-vault fairness)" do
    Application.put_env(:engram, :fanout_pacing_enabled, true)
    Application.put_env(:engram, :fanout_hot_window_ms, 60_000)
    Application.put_env(:engram, :fanout_drain_batch, 1)
    Application.put_env(:engram, :fanout_drain_interval_ms, 50)

    ta = "sync:u4:va"
    tb = "sync:u4:vb"
    EngramWeb.Endpoint.subscribe(ta)
    EngramWeb.Endpoint.subscribe(tb)

    FanoutPacer.emit(ta, "note_yjs_update", payload("a1"), "a1")
    FanoutPacer.emit(tb, "note_yjs_update", payload("b1"), "b1")

    # Both topics get a frame within the first tick (not serialized behind each other).
    assert_receive %Phoenix.Socket.Broadcast{topic: ^ta}, 200
    assert_receive %Phoenix.Socket.Broadcast{topic: ^tb}, 200
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/engram/notes/fanout_pacer_test.exs -k "hot frame"`
Expected: FAIL — the second `live` frame is classified cold and queues behind the 20 genesis frames (arrives well after 60ms), because `hot_window_ms` was raised to 60s in Task 2's test but the classifier already exists... Actually the hot classifier lands in Task 1's `cold?/1`, so this test verifies the END-TO-END bypass wiring. If it already passes, that confirms Task 1's classifier; keep the test as the #1002 regression guard and proceed. The `:sweep` step below is the only new code.

- [ ] **Step 3: Add the ETS sweep**

Add to `init/1`, replacing the `{:ok, ...}` return:

```elixir
    Process.send_after(self(), :sweep, sweep_interval_ms())
    {:ok, %{queues: %{}, draining: false}}
```

Add the sweep handler and its interval reader:

```elixir
  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - hot_window_ms()
    # Delete every note whose last-seen time is at/older than the cutoff.
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, sweep_interval_ms())
    {:noreply, state}
  end

  defp sweep_interval_ms, do: pos_env(:fanout_sweep_interval_ms, 30_000)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram/notes/fanout_pacer_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/fanout_pacer.ex test/engram/notes/fanout_pacer_test.exs
git commit -S -m "feat(crdt): hot-bypass fairness + ETS sweep"
```

---

### Task 4: Wire the two emit sites to `FanoutPacer.emit/4`

**Files:**
- Modify: `lib/engram/notes/crdt_persistence.ex:147-155`
- Modify: `lib/engram/notes/crdt_deliver.ex:108-116`
- Test: `test/engram/notes/fanout_pacer_wiring_test.exs`

**Interfaces:**
- Consumes: `FanoutPacer.emit/4`
- Produces: nothing new (behavior-preserving swap under pacing-disabled default)

- [ ] **Step 1: Write the failing test**

Create `test/engram/notes/fanout_pacer_wiring_test.exs`:

```elixir
defmodule Engram.Notes.FanoutPacerWiringTest do
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  test "a non-CRDT-origin write still fans out note_yjs_update via the pacer", %{
    user: user,
    vault: vault
  } do
    # Pacing is OFF in test env (config/test.exs) → pacer emits inline, so the
    # fan-out is observable synchronously exactly as before the swap.
    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "w.md", "content" => "# W", "mtime" => 1.0})

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "note_yjs_update",
                     payload: %{"note_id" => note_id}
                   },
                   500

    assert note_id == note.id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/fanout_pacer_wiring_test.exs`
Expected: This may already PASS if `deliver_out` fires today. If it passes pre-change, it is a guard confirming the swap keeps behavior. Proceed to make the swap and keep it green. (If it FAILS because `fanout_idle` requires CRDT state the upsert did not persist, add a first CRDT edit before asserting — but `upsert_note` merges into CRDT state, so `load_merged_state` returns bytes and the fan-out fires.)

- [ ] **Step 3: Make the swap**

In `lib/engram/notes/crdt_persistence.ex`, replace the `Broadcast.emit(...)` block inside `update_v1/4` (the one emitting `"note_yjs_update"`) with:

```elixir
        Engram.Notes.FanoutPacer.emit(
          "sync:#{user_id}:#{vault_id}",
          "note_yjs_update",
          %{
            "note_id" => note_id,
            "b64" => Base.encode64(update),
            "head" => CrdtTransport.head_marker(doc)
          },
          note_id
        )
```

In `lib/engram/notes/crdt_deliver.ex`, replace the `Broadcast.emit(...)` inside `fanout_idle/3` with:

```elixir
        Engram.Notes.FanoutPacer.emit(
          "sync:#{user_id}:#{vault_id}",
          "note_yjs_update",
          %{
            "note_id" => note_id,
            "b64" => Base.encode64(state),
            "head" => head
          },
          note_id
        )
```

Leave the surrounding comments in both files (they still describe the payload contract and the `head`/gap-heal semantics — still accurate). The `alias Engram.Sync.Broadcast` in both modules stays (other `Broadcast.emit` / `Broadcast.emit_from` calls remain).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram/notes/fanout_pacer_wiring_test.exs test/engram/crdt_sync_handoff_test.exs test/engram/notes_broadcast_test.exs`
Expected: PASS (existing broadcast/handoff tests unaffected — pacing is off in test env).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/crdt_persistence.ex lib/engram/notes/crdt_deliver.ex test/engram/notes/fanout_pacer_wiring_test.exs
git commit -S -m "fix(crdt): route note_yjs_update fan-out through FanoutPacer"
```

---

### Task 5: Full verification + PR

**Files:** none (verification + PR only)

- [ ] **Step 1: Format, lint, typecheck**

```bash
mix format
mix credo --strict
mix sobelow --config
mix dialyzer
```
Expected: all clean. Fix any warning at its root (no `# credo:disable`, no `# type: ignore`).

- [ ] **Step 2: Full suite**

Run: `mix test`
Expected: 0 failures. (If an unrelated pre-existing failure appears, surface it — do not skip it.)

- [ ] **Step 3: Sanity-check the fix against the issue**

Confirm both emit sites now route through the pacer and pacing defaults ON in prod:

```bash
grep -n "FanoutPacer.emit" lib/engram/notes/crdt_persistence.ex lib/engram/notes/crdt_deliver.ex
grep -n "fanout_pacing_enabled" config/*.exs
```
Expected: two `FanoutPacer.emit` hits; `config/test.exs` sets `false`; no prod override (default `true` from the module).

- [ ] **Step 4: Push + open PR**

```bash
git push -u origin fix/vault-channel-fanout-throttle
gh pr create --title "fix(crdt): pace vault-channel fan-out so genesis can't starve live edits (#1002)" \
  --body "Closes #1002

Adds \`Engram.Notes.FanoutPacer\`: hot (recently-active) notes fan out
immediately; cold bulk-enrollment frames drain per-vault at a bounded rate,
room-free and never dropped. Fixes large-vault reconnect starving live edits
~30s+ on the single \`sync:\` topic. Server-only; no plugin change. Spec in the
Engram vault (\`50 Engineering/_Superpowers Specs/2026-07-13-vault-channel-fanout-pacer-design.md\`).

Config knobs (defaults): \`fanout_hot_window_ms=2000\`, \`fanout_drain_batch=20\`,
\`fanout_drain_interval_ms=100\`, \`fanout_pacing_enabled=true\` (flip false = instant rollback).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 5: Verify CI green**

Run: `gh pr checks --watch`
Expected: all required checks pass. Never admin-bypass a red check — make it green.

---

## Self-Review

**1. Spec coverage:**
- Component `FanoutPacer` (GenServer + ETS) → Tasks 1–3. ✔
- Classification at call site via ETS → Task 1 `cold?/1`. ✔
- Per-vault paced drain + fairness → Tasks 2–3. ✔
- Hot bypass (#1002 scenario) → Task 3 regression test. ✔
- 4 config knobs + disabled passthrough → Task 1 + `config/test.exs`. ✔ (`fanout_sweep_interval_ms` added in Task 3 as an implied 5th knob for the sweep — documented in-code.)
- Two emit-site swaps → Task 4. ✔
- ETS sweep / growth bound → Task 3. ✔
- No-data-loss / reordering-via-gap-heal → accepted risks, covered by the hot-bypass + drain tests; no code owed. ✔
- Testing (a)(b)(c)(d) → Tasks 2–3 map to cold-drain / hot-bypass / two-topic / disabled-inline. ✔

**2. Placeholder scan:** No TBD/TODO; every code step shows full code. ✔

**3. Type consistency:** `emit/4` arity/signature identical across Tasks 1 and 4; `drain_topic/3`, `ensure_draining/1`, `pos_env/2`, `cold?/1` names consistent; `@table :fanout_hot` used uniformly. ✔
