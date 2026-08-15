defmodule EngramWeb.CrdtChannelDrainTest do
  @moduledoc """
  The half of the #1152 room-lifetime model that can actually lose data.

  A client edit is a `sync_update` frame, which y_ex dispatches as a
  `GenServer.cast` (`deps/y_ex/lib/server/doc_server_worker.ex:26`). A cast to a
  dead pid returns `:ok` and drops the frame — `crdt_channel.ex` says so at its
  room monitor: "send_yjs_message casts to a dead pid return :ok and every
  subsequent edit is silently dropped." Today that only happens on a crash. An
  idle-exit would make it happen on a timer, on purpose, which is why the room
  is drained (observers let go first) rather than stopped.

  The drain closes the window by MESSAGE ORDERING, so these tests pin both
  orderings. Both `push/3` and the drain are sent from the test process, so
  Erlang's per-sender-pair FIFO guarantee makes the interleaving deterministic
  rather than a race these tests would flake on.

  Materialization is the assertion because it is the user-visible loss: if a
  frame is cast into a corpse, no room ever applies it and nothing reaches the
  row, no matter which checkpoint path runs.
  """
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtChannelDrainTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "base"})

    {:ok, _, socket} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket.channel_pid)

    %{socket: socket, user: user, vault: vault, note: note}
  end

  # Drive the channel to start + observe the room, and hand back its pid.
  defp open_room(socket, note) do
    client = CrdtBridge.new_doc()
    push_step1(socket, note, client)

    room = CrdtRegistry.lookup(note.id)
    assert is_pid(room)
    {client, room}
  end

  # A handshake, NOT an edit. Opens the room through ensure_room while changing
  # no content — which matters for the announce tests: a content-changing
  # checkpoint fires its own `crdt_doc_ready` (crdt_checkpoint.ex:213), so
  # re-spinning with an edit makes the two announce sources indistinguishable.
  defp push_step1(socket, note, client) do
    {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(frame)})
    assert_push "crdt_msg", %{"doc_id" => _, "b64" => _}, 3_000
  end

  # A sync_update frame carrying `content` as the note's full plaintext.
  defp edit_frame(client, content) do
    :ok = CrdtBridge.ingest_plaintext(client, content)
    {:ok, update} = Yex.encode_state_as_update(client)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  defp assert_content_eventually(user, vault, note_id, needle, deadline \\ 3_000) do
    stop = System.monotonic_time(:millisecond) + deadline

    Stream.repeatedly(fn ->
      case Notes.get_note_by_id(user, vault, note_id) do
        {:ok, %{content: c}} when is_binary(c) -> c
        _ -> ""
      end
    end)
    |> Enum.reduce_while(nil, fn content, _ ->
      cond do
        content =~ needle -> {:halt, :ok}
        System.monotonic_time(:millisecond) >= stop -> {:halt, {:error, content}}
        true -> Process.sleep(25) && {:cont, nil}
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, last} ->
        flunk("#{inspect(needle)} never materialized; last content: #{inspect(last)}")
    end
  end

  test "an edit already queued when the drain lands is not lost", ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    {client, room} = open_room(socket, note)

    # [edit, drain] — the edit is ahead of the drain in the channel's mailbox,
    # so it must be routed to the still-live room before the room is released.
    push(socket, "crdt_msg", %{
      "doc_id" => note.id,
      "b64" => edit_frame(client, "EDIT BEFORE DRAIN")
    })

    send(socket.channel_pid, {:crdt_room_drain, room})

    assert_content_eventually(user, vault, note.id, "EDIT BEFORE DRAIN")
  end

  test "an edit arriving after the drain re-spins a fresh room instead of casting into a corpse",
       ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    {client, room} = open_room(socket, note)

    # [drain, edit] — the drain evicts the cached pid FIRST, so the edit behind
    # it must re-resolve through ensure_room rather than cast at the dead room.
    send(socket.channel_pid, {:crdt_room_drain, room})

    push(socket, "crdt_msg", %{
      "doc_id" => note.id,
      "b64" => edit_frame(client, "EDIT AFTER DRAIN")
    })

    assert_content_eventually(user, vault, note.id, "EDIT AFTER DRAIN")

    respun = CrdtRegistry.lookup(note.id)
    assert is_pid(respun)
    refute respun == room, "the edit must land on a NEW room, not the drained one"
  end

  # The whole point of the feature is bounding memory, so "did a room actually
  # get released" has to be observable in prod, not just in a test.
  test "a released room emits the telemetry ops needs to see the drain working", ctx do
    %{socket: socket, note: note} = ctx
    {_client, room} = open_room(socket, note)

    test_pid = self()
    handler = "drain-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :crdt, :room_drain],
      fn _e, measurements, meta, _ -> send(test_pid, {:drain_telemetry, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    send(socket.channel_pid, {:crdt_room_drain, room})

    assert_receive {:drain_telemetry, %{count: 1}, %{phase: :released}}, 3_000
  end

  test "a drain broadcast on the room's topic reaches the channel and releases the room", ctx do
    %{socket: socket, vault: vault, note: note} = ctx
    {_client, room} = open_room(socket, note)
    ref = Process.monitor(room)

    # The real wiring: the idle timer broadcasts, the channel is subscribed.
    Phoenix.PubSub.broadcast(
      Engram.PubSub,
      CrdtRegistry.drain_topic(vault.id),
      {:crdt_room_drain, room}
    )

    # Channel was the only observer, so letting go trips auto_exit.
    assert_receive {:DOWN, ^ref, :process, ^room, :normal}, 5_000
  end

  # The production shape: two devices on one note share ONE room, so the drain
  # has to be handled by every observer and the exit must happen exactly once,
  # on the last release. A drain that assumed a single observer would either
  # strand the room (nobody else lets go) or exit it under a live observer.
  test "a drain releases EVERY observer, and the room exits on the last one", ctx do
    %{socket: socket_a, user: user, vault: vault, note: note} = ctx
    {_client, room} = open_room(socket_a, note)

    {:ok, _, socket_b} =
      subscribe_and_join(
        socket(EngramWeb.UserSocket, "user_#{user.id}_b", %{
          current_user: user,
          current_api_key: nil
        }),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket_b.channel_pid)
    {_client_b, ^room} = open_room(socket_b, note)

    ref = Process.monitor(room)

    Phoenix.PubSub.broadcast(
      Engram.PubSub,
      CrdtRegistry.drain_topic(vault.id),
      {:crdt_room_drain, room}
    )

    assert_receive {:DOWN, ^ref, :process, ^room, :normal}, 5_000
  end

  # The announce is a DISCOVERY signal and recipients answer it with a
  # syncStep1. A drain->edit->re-spin discovers nothing (every peer already
  # heard about this note), so re-announcing would turn every drain cycle into a
  # handshake fanned out to every other device on the vault — against @hs_limit
  # here and the plugin's 240/10s crdt_msg budget, with handshake starvation
  # being the documented trigger for the wrong-mint overwrite class.
  test "a re-spin after a drain does NOT re-announce crdt_doc_ready", ctx do
    %{socket: socket, note: note} = ctx
    {client, room} = open_room(socket, note)

    # The FIRST open announces — pin that, so this test cannot pass by the
    # announce being broken outright.
    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}

    send(socket.channel_pid, {:crdt_room_drain, room})
    push_step1(socket, note, client)

    refute_broadcast "crdt_doc_ready", %{"doc_id" => _}, 300
  end

  # The suppression above is only safe because SOMETHING ELSE re-signals: for
  # `.md`, CrdtCheckpoint calls CrdtDeliver.announce_ready/4 on the next
  # content-changing checkpoint. That call is path-gated to `.md`
  # (crdt_deliver.ex:134) — so for a `.canvas`, which syncs through these same
  # rooms with no extension gate, the suppressed announce is the ONLY re-attach
  # signal a detached peer would ever get.
  #
  # Two devices on a canvas, room drains, both let go: the device whose user is
  # drawing re-spins the room, and the device that is only WATCHING is attached
  # to nothing and told nothing. It stays frozen until its own user draws.
  test "a re-spin after a drain DOES re-announce for a note the checkpoint won't", ctx do
    %{socket: socket, user: user, vault: vault} = ctx

    {:ok, canvas} =
      Notes.upsert_note(user, vault, %{"path" => "board.canvas", "content" => "{}"})

    {client, room} = open_room(socket, canvas)
    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}

    send(socket.channel_pid, {:crdt_room_drain, room})
    push_step1(socket, canvas, client)

    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}, 3_000
  end

  # Suppression is consumed once per drain, not latched: a crash-shaped
  # eviction still announces, because THAT peer state is genuinely unknown.
  test "only the drain-induced re-spin is suppressed, not every later open", ctx do
    %{socket: socket, note: note} = ctx
    {client, room} = open_room(socket, note)
    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}

    # Drain -> re-spin is quiet.
    send(socket.channel_pid, {:crdt_room_drain, room})
    push_step1(socket, note, client)
    refute_broadcast "crdt_doc_ready", %{"doc_id" => _}, 300

    # Crash-shaped eviction (no drain recorded) -> announces again.
    respun = CrdtRegistry.lookup(note.id)
    send(socket.channel_pid, {:DOWN, make_ref(), :process, respun, :crashed})
    push_step1(socket, note, client)
    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}, 3_000
  end

  # A room that could not be released is the case the drain must NOT forget.
  # The channel is still in the room's observer_process map, so auto_exit can
  # never fire for it; if the channel drops the cached pid anyway, every later
  # re-ask matches nothing ("not ours") and the room is pinned for the life of
  # the socket. That is the unbounded residency this whole feature exists to
  # prevent, and it is invisible: no crash, no log, no failing assertion.
  #
  # `:sys.suspend/1` is how a REAL room is made unresponsive without faking
  # y_ex's message shapes — a suspended GenServer accepts the call and never
  # answers it, which is exactly a wedged room.
  describe "a room that refuses to release" do
    setup do
      prev = Application.get_env(:engram, :crdt_room_probe_ms)
      Application.put_env(:engram, :crdt_room_probe_ms, 100)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:engram, :crdt_room_probe_ms)
          v -> Application.put_env(:engram, :crdt_room_probe_ms, v)
        end
      end)

      test_pid = self()
      handler = "drain-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :room_drain],
        fn _e, m, meta, _ -> send(test_pid, {:drain_telemetry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "is kept cached, so the timer's re-ask can actually retry it", ctx do
      %{socket: socket, note: note} = ctx
      {_client, room} = open_room(socket, note)

      :sys.suspend(room)
      on_exit(fn -> if Process.alive?(room), do: :sys.resume(room) end)

      send(socket.channel_pid, {:crdt_room_drain, room})
      assert_receive {:drain_telemetry, _, %{phase: :skipped_unresponsive}}, 2_000

      # THE assertion: ask again. If the first drain had evicted the pid, this
      # second one would hit the "not ours" no-op and emit nothing at all.
      send(socket.channel_pid, {:crdt_room_drain, room})
      assert_receive {:drain_telemetry, _, %{phase: :skipped_unresponsive}}, 2_000
    end

    test "is released once it recovers, rather than staying pinned forever", ctx do
      %{socket: socket, note: note} = ctx
      {_client, room} = open_room(socket, note)

      :sys.suspend(room)
      send(socket.channel_pid, {:crdt_room_drain, room})
      assert_receive {:drain_telemetry, _, %{phase: :skipped_unresponsive}}, 2_000

      :sys.resume(room)

      send(socket.channel_pid, {:crdt_room_drain, room})
      assert_receive {:drain_telemetry, _, %{phase: :released}}, 2_000
    end
  end

  # `SharedDoc.unobserve/1` is a GenServer.call with y_ex's 5 s default and no
  # timeout knob, so a dead or wedged room would exit or stall the channel.
  # These drive release_room/1 with PLAIN processes that simply do not reply —
  # no y_ex message shapes encoded here, so the tests keep meaning across a dep
  # bump. The responsive path is covered end-to-end by the drain tests above.
  describe "release_room/1" do
    defp elapsed_ms(fun) do
      t0 = System.monotonic_time(:millisecond)
      result = fun.()
      {result, System.monotonic_time(:millisecond) - t0}
    end

    test "a room that already exited is a fast no-op, not a channel-killing exit" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      {result, ms} = elapsed_ms(fn -> EngramWeb.CrdtChannel.release_room(dead) end)

      # :gone, not :retry — there is no observer entry left to shed, so the
      # caller MUST forget this room rather than keep re-asking a corpse.
      assert result == :gone
      assert ms < 500, "a dead room should short-circuit, took #{ms}ms"
    end

    test "a wedged room is abandoned at the probe, not held for the 5s call default" do
      # Assert against a SHORT configured probe rather than racing the 1s
      # default on a loaded shared runner — the timing headroom is what keeps
      # this from flaking.
      # DELETE on restore when the key was previously unset. put_env(…, nil)
      # would leave the key PRESENT with a nil value, which is not the same as
      # absent — it poisoned every later test in this file with `timeout: nil`.
      prev = Application.get_env(:engram, :crdt_room_probe_ms)
      Application.put_env(:engram, :crdt_room_probe_ms, 100)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:engram, :crdt_room_probe_ms)
          v -> Application.put_env(:engram, :crdt_room_probe_ms, v)
        end
      end)

      wedged = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      {result, ms} = elapsed_ms(fn -> EngramWeb.CrdtChannel.release_room(wedged) end)

      # :retry is the whole point. The room is ALIVE and still holds this
      # process in its observer_process map, so auto_exit can never fire for it.
      # A caller that forgot it here would strand the room for the life of the
      # socket AND make every backed-off re-ask a no-op — the unbounded
      # residency this feature exists to prevent.
      assert result == :retry
      # The point: bounded by the probe, nowhere near y_ex's 5_000ms default.
      assert ms < 1_000, "a wedged room stalled the channel for #{ms}ms"
    end

    # Rooms are `:global`-registered, so a channel on this node routinely
    # observes a room on ANOTHER node. `Process.alive?/1` is local-only and
    # raises ArgumentError on a remote pid — :error class, which the `catch
    # :exit` in release_room/1 does NOT contain. Unguarded, every drain of a
    # remote room crashes the channel, in a cluster that has been live in prod
    # since 2026-06-23.
    #
    # NOTE: `:cluster` is excluded unless CLUSTER_TESTS=1, and nothing in CI
    # sets it — so this does not currently gate a merge. It is still the only
    # executable proof of the guard; run it with
    #   CLUSTER_TESTS=1 mix test test/engram_web/channels/crdt_channel_drain_test.exs
    @tag :cluster
    test "a room on ANOTHER node does not crash the channel" do
      # Engram.ClusterCase owns the net_kernel/cookie/code-path dance (and the
      # start-not-start_link subtlety around on_exit) — no reason to re-roll it.
      {_peer, peer_node} = Engram.ClusterCase.start_peer!([], &on_exit/1)

      remote = :erpc.call(peer_node, :erlang, :spawn, [:timer, :sleep, [60_000]])
      refute node(remote) == node()

      # The bug this pins RAISES rather than exits, so a bare call is the test:
      # an ArgumentError from Process.alive?/1 is :error class and would blow
      # straight through release_room/1's `catch :exit`.
      #
      # :retry, because a bare remote sleeper answers nothing: the node check
      # short-circuits (this is the guard under test), then the probe times out.
      # It therefore proves "no ArgumentError" and NOT the remote unobserve —
      # which still ships an anonymous closure to the peer via update_doc/3, and
      # is the part no single-node suite can speak to.
      assert EngramWeb.CrdtChannel.release_room(remote) == :retry
    end

    # The `:cluster` test below proves this against a real peer but does NOT run
    # in CI. This one covers the same guard on a single node by injecting the
    # "self" node instead of faking a remote pid: with a mismatched node the
    # check must short-circuit BEFORE Process.alive?/1, which is the local-only
    # call that raises. Drop the node guard and this flips to true.
    test "a pid whose node is not ours never reaches the local-only alive? check" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      refute EngramWeb.CrdtChannel.locally_dead?(dead, :somewhere@else)
      assert EngramWeb.CrdtChannel.locally_dead?(dead), "sanity: locally it IS dead"
    end

    # Locks the `|| @room_probe_ms` reader. A key SET to nil is not the same as
    # absent, and get_env/3's default would not fire — feeding `timeout: nil` to
    # GenServer.call/3, which is how one sloppy test restore crashed every later
    # test in this file.
    test "a nil-valued probe override still yields a usable timeout" do
      prev = Application.get_env(:engram, :crdt_room_probe_ms)
      Application.put_env(:engram, :crdt_room_probe_ms, nil)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:engram, :crdt_room_probe_ms)
          v -> Application.put_env(:engram, :crdt_room_probe_ms, v)
        end
      end)

      wedged = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      assert EngramWeb.CrdtChannel.release_room(wedged) == :retry
    end

    test "a skipped release is still counted, so ops can see rooms refusing to go" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      test_pid = self()
      handler = "skip-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :room_drain],
        fn _e, m, meta, _ -> send(test_pid, {:drain_telemetry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      EngramWeb.CrdtChannel.release_room(dead)

      # :skipped_dead, NOT a bare :skipped. A dead room and a wedged one are
      # different incidents — the first is routine, the second means a room is
      # pinned. One shared atom made the dashboard unable to tell "drained fine"
      # from "leaked", which is the failure this counter exists to surface.
      assert_receive {:drain_telemetry, %{count: 1}, %{phase: :skipped_dead}}, 1_000
    end

    test "an unresponsive room is counted under its own phase, not as a dead one" do
      prev = Application.get_env(:engram, :crdt_room_probe_ms)
      Application.put_env(:engram, :crdt_room_probe_ms, 100)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:engram, :crdt_room_probe_ms)
          v -> Application.put_env(:engram, :crdt_room_probe_ms, v)
        end
      end)

      wedged = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      test_pid = self()
      handler = "wedged-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :room_drain],
        fn _e, m, meta, _ -> send(test_pid, {:drain_telemetry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert EngramWeb.CrdtChannel.release_room(wedged) == :retry
      assert_receive {:drain_telemetry, %{count: 1}, %{phase: :skipped_unresponsive}}, 1_000
    end

    test "a room that dies mid-call is swallowed rather than exiting the channel" do
      # Answers the probe, then exits before the unobserve can land.
      dying =
        spawn(fn ->
          receive do
            {:"$gen_call", from, _} -> GenServer.reply(from, :ok)
          end

          exit(:normal)
        end)

      # :gone — a room that died mid-call is gone, so forgetting it is correct.
      # Contrast the {:timeout, _} exit, which means the room is still alive.
      assert EngramWeb.CrdtChannel.release_room(dying) == :gone
    end
  end

  # assigns.drained holds a doc_id until its re-spin consumes it — but a note
  # drained and never re-opened leaves one behind for the life of the socket,
  # and @default_max_rooms bounds CONCURRENT rooms, not cumulative ones, while
  # drain-churn is the intended steady state.
  describe "remember_drained/3" do
    test "accumulates entries below the cap" do
      set =
        Enum.reduce(1..5, MapSet.new(), &EngramWeb.CrdtChannel.remember_drained(&2, "d#{&1}", 10))

      assert MapSet.size(set) == 5
    end

    # Overflow CLEARS rather than evicting: the degradation is only ever lost
    # suppression (a re-spin announces, i.e. pre-drain behaviour), never
    # incorrectness — so it needs no ordering bookkeeping.
    test "clears at the cap instead of growing without bound" do
      set =
        Enum.reduce(
          1..50,
          MapSet.new(),
          &EngramWeb.CrdtChannel.remember_drained(&2, "d#{&1}", 10)
        )

      assert MapSet.size(set) <= 10
    end
  end

  # The drain subscription is PER CONNECTION, not per room. Per-room cost a
  # subscription for every note the enroll-everything client opens: measured at
  # 309 bytes each, ~725 KB per socket on a 2400-note vault and ~707 MB per 1000
  # such clients — against the same 1024 MB task whose memory this feature
  # exists to protect. A correctness suite cannot catch that; only counting can.
  test "opening many rooms adds no drain subscriptions — one per connection", ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    topic = CrdtRegistry.drain_topic(vault.id)

    # Counting via the Registry backing Phoenix.PubSub. If PubSub ever stops
    # being Registry-backed this raises rather than quietly passing, which is
    # the acceptable direction for that coupling.
    channel_subs = fn ->
      Engram.PubSub
      |> Registry.lookup(topic)
      |> Enum.count(fn {pid, _} -> pid == socket.channel_pid end)
    end

    assert channel_subs.() == 1, "the connection subscribes once, at join"

    {_client, _room} = open_room(socket, note)

    for n <- 1..5 do
      {:ok, extra} =
        Notes.upsert_note(user, vault, %{"path" => "n#{n}.md", "content" => "x"})

      push_step1(socket, extra, CrdtBridge.new_doc())
    end

    assert channel_subs.() == 1,
           "subscriptions must not scale with rooms opened — that is the memory bug"
  end

  test "a drain for a room this channel does not hold is ignored", ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    {client, room} = open_room(socket, note)

    send(socket.channel_pid, {:crdt_room_drain, self()})

    # The channel is still alive and still holding its real room.
    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => edit_frame(client, "STILL WORKING")})
    assert_content_eventually(user, vault, note.id, "STILL WORKING")
    assert CrdtRegistry.lookup(note.id) == room
  end
end
