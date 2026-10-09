defmodule Engram.Notes.NameIndex do
  @moduledoc """
  Node-local cache of per-vault name indexes for partial path/title search
  (MCP `completion/complete` today, web search next).

  Paths and titles are encrypted at rest and our HMACs only match whole
  values, so partial search must decrypt. Each vault's names are decrypted
  once, in one native call, into a Rust resource (`native/engram_native/src/
  names.rs`); searches run there and return only the top hits. Plaintext
  names never become Elixir terms, so they are not copied per search, not in
  ETS and not in crash dumps. ETS holds only handles.

  Freshness, three layers:

    * the owner subscribes to each cached vault's `sync:<user>:<vault>`
      topic, where `Notes.broadcast_change/6` announces REST/MCP creates,
      renames, moves and deletes with the plaintext path and title, from
      any node;
    * `announce/5` covers the writes that never reach that topic: CRDT
      genesis (every note created in Obsidian) and a checkpoint that
      changes a title;
    * every index is rebuilt after `@max_age_ms` regardless of use, so
      anything still missed (cross-node reordering, a rolled-back write)
      heals within minutes.

  A stale entry only means a stale suggestion: every read still resolves
  through the database and the credential's scope.

  Bursts: a cold vault is built once per burst (single flight; other callers
  wait and get the same handle), events arriving mid-build are buffered and
  replayed, and per client only the newest search runs; an older one still
  waiting returns `:superseded`.
  """

  use GenServer

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Native
  alias Engram.Notes
  alias Engram.Repo

  require Logger

  @table :engram_name_index
  @tickets :engram_name_index_tickets
  @idle_ms :timer.minutes(10)
  @max_age_ms :timer.minutes(5)
  @sweep_ms :timer.minutes(1)
  @max_bytes 128 * 1024 * 1024
  @build_timeout :timer.seconds(30)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `{:ok, paths, total}` best first, `:superseded` when the same `client`
  sent a newer search for this vault while this one waited, or `:error` when
  the index cannot be built. `vault` must already be scope-checked.
  """
  def search(user, vault, query, limit, client \\ nil) do
    key = {user.id, vault.id, client}
    ticket = :ets.update_counter(@tickets, key, 1, {key, 0})

    with {:ok, handle} <- fetch(user, vault),
         true <- latest?(key, ticket) || :superseded do
      GenServer.cast(__MODULE__, {:touch, vault.id})
      {paths, total} = Native.name_index_search(handle, query, limit)
      {:ok, paths, total}
    end
  end

  @doc """
  Tells every node's index that a note now has this path and title. For
  writes that do not go through `Notes.broadcast_change/6` (CRDT genesis, a
  checkpoint that re-derives the title). Cheap when nothing is cached: one
  PubSub publish with no subscribers.
  """
  def announce(vault_id, note_id, path, title) when is_binary(note_id) and is_binary(path) do
    Phoenix.PubSub.broadcast(
      Engram.PubSub,
      announce_topic(vault_id),
      {:name_index_put, vault_id, note_id, path, title || ""}
    )
  end

  # A ticket swept away mid-request counts as latest.
  defp latest?(key, ticket) do
    case :ets.lookup(@tickets, key) do
      [{_, current}] -> current == ticket
      [] -> true
    end
  end

  defp fetch(user, vault) do
    case :ets.lookup(@table, vault.id) do
      [{_, user_id, handle, _bytes, _used, built}] when user_id == user.id ->
        if fresh?(built), do: {:ok, handle}, else: build_once(user, vault)

      _ ->
        build_once(user, vault)
    end
  end

  # Single flight: the first caller builds, the rest wait for its result.
  defp build_once(user, vault) do
    case GenServer.call(__MODULE__, {:claim, user.id, vault.id}, @build_timeout) do
      {:ready, handle} -> {:ok, handle}
      :error -> :error
      :build -> build(user, vault)
    end
  catch
    # A build slower than the timeout: answer empty rather than crash the request.
    :exit, {:timeout, _} -> :error
  end

  defp build(user, vault) do
    rows = Repo.with_tenant!(user.id, fn -> raw_rows(user, vault) end)
    {:ok, dek} = Crypto.get_dek(user)

    result =
      Native.name_index_build(
        dek,
        Crypto.aad_prefix(:notes, :path),
        Crypto.aad_prefix(:notes, :title),
        rows
      )

    case result do
      {:ok, handle, bytes} ->
        GenServer.call(__MODULE__, {:built, vault.id, handle, bytes}, @build_timeout)
        {:ok, handle}

      :error ->
        Logger.error("name_index build failed: undecryptable name", vault_id: vault.id)
        GenServer.call(__MODULE__, {:failed, vault.id})
        :error
    end
  end

  defp raw_rows(user, vault) do
    bound = Crypto.row_version_aad_bound()

    Repo.all(
      from(n in Notes.scoped_live(user, vault),
        where: n.kind == "note",
        select:
          {fragment("uuid_send(?)", n.id),
           fragment("coalesce(? >= ?, false)", n.dek_version, ^bound), n.path_ciphertext,
           n.path_nonce, n.title_ciphertext, n.title_nonce}
      )
    )
  end

  @doc "Drops every cached index on this node (tests)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  # -- Owner --

  @impl true
  def init(_opts) do
    # Broadcasts it receives carry plaintext paths and titles.
    Process.flag(:sensitive, true)
    _ = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    _ = :ets.new(@tickets, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, %{building: %{}}}
  end

  @impl true
  def handle_call({:claim, user_id, vault_id}, {pid, _} = from, state) do
    cached = :ets.lookup(@table, vault_id)

    case {cached, state.building[vault_id]} do
      {[{_, ^user_id, handle, _, _, built}], nil} ->
        if fresh?(built) do
          {:reply, {:ready, handle}, state}
        else
          drop(vault_id, user_id)
          start_build(state, pid, user_id, vault_id)
        end

      {_, %{user_id: ^user_id} = b} ->
        {:noreply, put_in(state.building[vault_id], %{b | waiters: [from | b.waiters]})}

      # Defense in depth: never hand one user's build to another.
      {_, %{}} ->
        {:reply, :error, state}

      _ ->
        start_build(state, pid, user_id, vault_id)
    end
  end

  def handle_call({:built, vault_id, handle, bytes}, _from, state) do
    case pop_in(state.building[vault_id]) do
      {nil, state} ->
        {:reply, :ok, state}

      {b, state} ->
        # Changes that landed while the builder read and decrypted.
        b.events |> Enum.reverse() |> Enum.each(&apply_event(handle, &1))
        :ets.insert(@table, {vault_id, b.user_id, handle, bytes, now(), now()})
        finish(b, {:ready, handle})
        enforce_cap()
        {:reply, :ok, state}
    end
  end

  def handle_call({:failed, vault_id}, _from, state) do
    {:reply, :ok, abandon(state, vault_id)}
  end

  def handle_call(:clear, _from, state) do
    for {vault_id, user_id, _, _, _, _} <- :ets.tab2list(@table), do: drop(vault_id, user_id)
    {:reply, :ok, state}
  end

  defp start_build(state, pid, user_id, vault_id) do
    # Subscribe BEFORE the builder reads rows; events until :built are buffered.
    :ok = Phoenix.PubSub.subscribe(Engram.PubSub, topic(user_id, vault_id))
    :ok = Phoenix.PubSub.subscribe(Engram.PubSub, announce_topic(vault_id))
    ref = Process.monitor(pid)
    b = %{builder: {pid, ref}, user_id: user_id, waiters: [], events: []}
    {:reply, :build, put_in(state.building[vault_id], b)}
  end

  defp abandon(state, vault_id) do
    case pop_in(state.building[vault_id]) do
      {nil, state} ->
        state

      {b, state} ->
        finish(b, :error)
        unsubscribe(b.user_id, vault_id)
        state
    end
  end

  defp finish(%{builder: {_pid, ref}, waiters: waiters}, reply) do
    Process.demonitor(ref, [:flush])
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  @impl true
  def handle_cast({:touch, vault_id}, state) do
    _ = :ets.update_element(@table, vault_id, {5, now()})
    {:noreply, state}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "note_changed", payload: payload}, state) do
    {:noreply, route(event_of(payload), state)}
  end

  def handle_info({:name_index_put, vault_id, id, path, title}, state) do
    {:noreply, route(put_event(vault_id, id, path, title), state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.building, fn {_, b} -> elem(b.builder, 1) == ref end) do
      nil -> {:noreply, state}
      {vault_id, _} -> {:noreply, abandon(state, vault_id)}
    end
  end

  def handle_info(:sweep, state) do
    idle = now() - @idle_ms

    for {vault_id, user_id, _, _, used, built} <- :ets.tab2list(@table),
        used < idle or not fresh?(built),
        do: drop(vault_id, user_id)

    # Patches grow an index past its build-time size; re-measure, then cap.
    for {vault_id, _, handle, _, _, _} <- :ets.tab2list(@table),
        do: :ets.update_element(@table, vault_id, {4, Native.name_index_bytes(handle)})

    enforce_cap()
    # A ticket only orders searches already in flight; a sweep cannot lose one.
    :ets.delete_all_objects(@tickets)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp event_of(%{"vault_id" => vault_id, "event_type" => "upsert", "id" => id} = p),
    do: put_event(vault_id, id, p["path"] || "", p["title"] || "")

  defp event_of(%{"vault_id" => vault_id, "event_type" => "delete", "id" => id} = p) do
    case Ecto.UUID.dump(id) do
      {:ok, raw} -> {vault_id, {:delete, raw, p["path"] || ""}}
      :error -> nil
    end
  end

  defp event_of(_payload), do: nil

  defp put_event(vault_id, id, path, title) do
    case Ecto.UUID.dump(id) do
      {:ok, raw} -> {vault_id, {:put, raw, path, title}}
      :error -> nil
    end
  end

  # Patch a cached index, buffer for one being built, else drop.
  defp route(nil, state), do: state

  defp route({vault_id, event}, state) do
    case {:ets.lookup(@table, vault_id), state.building[vault_id]} do
      {_, %{} = b} ->
        put_in(state.building[vault_id], %{b | events: [event | b.events]})

      {[{_, _, handle, _, _, _}], nil} ->
        apply_event(handle, event)
        state

      _ ->
        state
    end
  end

  defp apply_event(handle, {:put, raw, path, title}),
    do: Native.name_index_put(handle, raw, path, title)

  defp apply_event(handle, {:delete, raw, path}), do: Native.name_index_delete(handle, raw, path)

  # LRU down to the cap.
  defp enforce_cap do
    entries = :ets.tab2list(@table)
    total = Enum.reduce(entries, 0, fn e, acc -> acc + elem(e, 3) end)

    if total > @max_bytes do
      _left =
        entries
        |> Enum.sort_by(&elem(&1, 4))
        |> Enum.reduce_while(total, fn {vault_id, user_id, _, b, _, _}, left ->
          drop(vault_id, user_id)
          if left - b > @max_bytes, do: {:cont, left - b}, else: {:halt, left - b}
        end)
    end

    :ok
  end

  # The handle's native memory is freed once no process references it.
  defp drop(vault_id, user_id) do
    :ets.delete(@table, vault_id)
    unsubscribe(user_id, vault_id)
  end

  # Unregisters every subscription this process holds on each topic.
  defp unsubscribe(user_id, vault_id) do
    Phoenix.PubSub.unsubscribe(Engram.PubSub, topic(user_id, vault_id))
    Phoenix.PubSub.unsubscribe(Engram.PubSub, announce_topic(vault_id))
  end

  defp fresh?(built), do: now() - built < @max_age_ms
  defp topic(user_id, vault_id), do: "sync:#{user_id}:#{vault_id}"
  defp announce_topic(vault_id), do: "name_index:#{vault_id}"
  defp now, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
