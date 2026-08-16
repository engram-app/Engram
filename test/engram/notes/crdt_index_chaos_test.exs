defmodule Engram.Notes.CrdtIndexChaosTest do
  @moduledoc """
  Randomised lifecycle chaos over the index room's durability.

  The example-based tests each pin ONE ordering: write-then-kill, write-then-
  checkpoint, two-writes-one-checkpoint. Every bug this subsystem has actually
  shipped came from an ordering nobody wrote a test for — the checkpoint that
  pruned a row it had not folded in, the bind that echoed its own replay back
  onto the tail, the snapshot that raced a rotation. Those are interleavings,
  not features, so they are enumerated here rather than hand-picked.

  A `model` map is the oracle: the last `note_id` written to each path is what
  the doc must hold, no matter what happened to the room in between. Ops are
  drawn from a SEEDED generator, so a failure is replayable — the seed is in
  the message.

  The one race deliberately excluded: `handle_update_v1` is asynchronous, so a
  write that has not yet reached the tail is legitimately lost by a kill (the
  client still holds it and retransmits on rejoin). The loop therefore waits
  for durability before it kills. What is asserted is the promise the design
  actually makes — ONCE DURABLE, NEVER LOST — not a stronger one it doesn't.
  """
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Repo, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry, VaultIndexUpdateLog}
  alias Yex.Sync.SharedDoc

  # Small path pool on purpose: reuse forces overwrite-same-key, which is where
  # last-writer-wins and tail replay ORDER start to matter. A wide pool would
  # make every op independent and test almost nothing.
  @paths ~w(a.md b.md c.md d/e.md d/f.md)
  @ops [:put, :put, :put, :kill, :stop, :rebind, :read]

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "IndexChaos"})
    %{user: user, vault: vault}
  end

  defp tail_count(user, vault_id) do
    {:ok, n} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in VaultIndexUpdateLog, where: l.vault_id == ^vault_id), :count)
      end)

    n
  end

  defp await_tail_growth(user, vault_id, baseline) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case tail_count(user, vault_id) do
        n when n > baseline ->
          {:halt, n}

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end) || flunk("a write never became durable (tail stayed at #{baseline})")
  end

  defp put(room, path, note_id) do
    :ok =
      SharedDoc.update_doc(room, fn doc ->
        doc
        |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
        |> Yex.Map.set(path, %{"note_id" => note_id})
      end)
  end

  defp read(room, path) do
    me = self()

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        send(
          me,
          {:read, path, doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.fetch(path)}
        )
      end)

    receive do
      {:read, ^path, {:ok, %{"note_id" => id}}} -> id
      {:read, ^path, _} -> nil
    after
      5_000 -> flunk("the room never answered a read of #{path}")
    end
  end

  defp start_room(%{user: user, vault: vault}) do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(user.id, vault.id)
    room
  end

  # Graceful: drop the last observer -> auto_exit -> terminate -> unbind ->
  # checkpoint. This is the path that writes a snapshot and prunes the tail.
  defp stop_room(room) do
    ref = Process.monitor(room)
    :ok = SharedDoc.unobserve(room)

    receive do
      {:DOWN, ^ref, :process, ^room, _} -> :ok
    after
      5_000 -> flunk("the room never exited after losing its last observer")
    end
  end

  # Violent: no terminate/2, so no unbind and no snapshot. Everything since the
  # last checkpoint has to come back from the tail alone.
  defp kill_room(room) do
    ref = Process.monitor(room)
    Process.exit(room, :kill)

    receive do
      {:DOWN, ^ref, :process, ^room, _} -> :ok
    after
      5_000 -> flunk("the room survived a kill")
    end
  end

  defp alive?(room), do: is_pid(room) and Process.alive?(room)

  defp step(:put, ctx, {room, model, baseline}) do
    room = if alive?(room), do: room, else: start_room(ctx)
    path = Enum.random(@paths)
    id = Ecto.UUID.generate()
    put(room, path, id)
    {room, Map.put(model, path, id), await_tail_growth(ctx.user, ctx.vault.id, baseline)}
  end

  defp step(:kill, ctx, {room, model, _baseline}) do
    if alive?(room), do: kill_room(room)
    {nil, model, tail_count(ctx.user, ctx.vault.id)}
  end

  defp step(:stop, ctx, {room, model, _baseline}) do
    if alive?(room), do: stop_room(room)
    {nil, model, tail_count(ctx.user, ctx.vault.id)}
  end

  defp step(:rebind, ctx, {room, model, baseline}) do
    if alive?(room),
      do: {room, model, baseline},
      else: {start_room(ctx), model, tail_count(ctx.user, ctx.vault.id)}
  end

  defp step(:read, ctx, {room, model, baseline}) do
    room = if alive?(room), do: room, else: start_room(ctx)
    path = Enum.random(@paths)

    assert read(room, path) == Map.get(model, path),
           "a live room disagreed with the model on #{path}"

    {room, model, baseline}
  end

  # Every path is checked against a room bound from scratch, so the assertion
  # reads the DURABLE state (snapshot + tail replay), never a doc that merely
  # happened to still be in memory.
  defp verify_from_cold_start(ctx, model, seed) do
    room = start_room(ctx)

    for {path, expected} <- model do
      assert read(room, path) == expected,
             "#{path} did not survive the lifecycle (seed #{inspect(seed)})"
    end

    stop_room(room)
  end

  describe "durability under a randomised room lifecycle" do
    for seed <- [{1, 2, 3}, {17, 41, 97}, {2026, 8, 16}] do
      @seed seed

      test "once durable, a claim survives any interleaving (seed #{inspect(seed)})", ctx do
        :rand.seed(:exsss, @seed)

        {room, model, _} =
          Enum.reduce(1..30, {nil, %{}, 0}, fn _, acc ->
            step(Enum.random(@ops), ctx, acc)
          end)

        if alive?(room), do: stop_room(room)

        refute model == %{}, "the generator produced no writes at all"
        verify_from_cold_start(ctx, model, @seed)
      end
    end

    # The tail is unbounded until #1151 step 3 generalises the checkpoint timer,
    # so what keeps it finite today is that a graceful exit prunes what it
    # folded in. If a checkpoint ever prunes MORE than it folded, the cold-start
    # check above goes red; if it prunes LESS, the tail grows forever and this
    # catches it.
    test "a graceful exit always leaves the tail empty", ctx do
      :rand.seed(:exsss, {5, 5, 5})

      {room, _model, _} =
        Enum.reduce(1..12, {nil, %{}, 0}, fn _, acc ->
          step(Enum.random([:put, :put, :kill, :rebind]), ctx, acc)
        end)

      room = if alive?(room), do: room, else: start_room(ctx)
      stop_room(room)

      assert tail_count(ctx.user, ctx.vault.id) == 0,
             "a checkpoint left rows behind it had already folded into the snapshot"
    end
  end
end
