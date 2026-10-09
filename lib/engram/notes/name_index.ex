defmodule Engram.Notes.NameIndex do
  @moduledoc """
  Node-local cache of per-vault name indexes for partial path/title search
  (MCP `completion/complete` today, web search next).

  Paths and titles are encrypted at rest and our HMACs only match whole
  values, so partial search must decrypt. Each vault's names are decrypted
  once, in one native call, into a Rust resource (`native/engram_native/src/
  names.rs`); searches run there and return only the top hits. Plaintext
  names never become Elixir terms, so they are not copied per search, not in
  ETS and not in crash dumps. ETS holds only `{vault_id, user_id, handle,
  bytes, last_used}`.

  Freshness: the owner subscribes to each cached vault's `sync:<user>:<vault>`
  topic, where `Notes.broadcast_change/6` already announces every create,
  rename, move and delete with the plaintext path and title, from any node,
  and patches the index in place. Content edits patch nothing that changes.
  A missed event only leaves a stale suggestion: every read still resolves
  through the database and the credential's scope. Idle indexes drop after
  `@idle_ms`, and the total is capped at `@max_bytes` (LRU).

  Bursts: a cold vault is built once per burst (single flight, other callers
  wait), and only the newest search per user and vault runs; an older one
  that is still waiting returns `:superseded`.
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
  @sweep_ms :timer.minutes(1)
  @max_bytes 128 * 1024 * 1024
  @build_timeout :timer.seconds(30)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `{:ok, paths, total}` best first, `:superseded` when a newer search for the
  same user and vault arrived first, or `:error` when the index cannot be
  built. `vault` must already be scope-checked by the caller.
  """
  def search(user, vault, query, limit) do
    key = {user.id, vault.id}
    ticket = :ets.update_counter(@tickets, key, 1, {key, 0})

    with {:ok, handle} <- fetch(user, vault),
         true <- latest?(key, ticket) || :superseded do
      GenServer.cast(__MODULE__, {:touch, vault.id})
      {paths, total} = Native.name_index_search(handle, query, limit)
      {:ok, paths, total}
    end
  end

  defp latest?(key, ticket), do: :ets.lookup_element(@tickets, key, 2) == ticket

  defp fetch(user, vault) do
    case :ets.lookup(@table, vault.id) do
      [{_, user_id, handle, _bytes, _used}] when user_id == user.id -> {:ok, handle}
      _ -> build_once(user, vault)
    end
  end

  # Single flight: the first caller builds, the rest wait for its result.
  defp build_once(user, vault) do
    case GenServer.call(__MODULE__, {:claim, user.id, vault.id}, @build_timeout) do
      {:ready, handle} -> {:ok, handle}
      :error -> :error
      :build -> build(user, vault)
    end
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
        GenServer.call(__MODULE__, {:built, user.id, vault.id, handle, bytes})
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
    case {:ets.lookup(@table, vault_id), state.building} do
      {[{_, ^user_id, handle, _, _}], _} ->
        {:reply, {:ready, handle}, state}

      {_, %{^vault_id => {builder, waiters}}} ->
        {:noreply, put_in(state.building[vault_id], {builder, [from | waiters]})}

      _ ->
        # Subscribe BEFORE the builder reads rows, so a change landing
        # mid-build is not lost (it may patch nothing yet; TTL backstops).
        :ok = Phoenix.PubSub.subscribe(Engram.PubSub, topic(user_id, vault_id))
        ref = Process.monitor(pid)
        {:reply, :build, put_in(state.building[vault_id], {{pid, ref}, []})}
    end
  end

  def handle_call({:built, user_id, vault_id, handle, bytes}, _from, state) do
    {entry, state} = pop_in(state.building[vault_id])
    :ets.insert(@table, {vault_id, user_id, handle, bytes, now()})
    reply_waiters(entry, {:ready, handle})
    enforce_cap()
    {:reply, :ok, state}
  end

  def handle_call({:failed, vault_id}, _from, state) do
    {entry, state} = pop_in(state.building[vault_id])
    reply_waiters(entry, :error)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    for {vault_id, user_id, _, _, _} <- :ets.tab2list(@table), do: drop(vault_id, user_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:touch, vault_id}, state) do
    _ = :ets.update_element(@table, vault_id, {5, now()})
    {:noreply, state}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "note_changed", payload: payload}, state) do
    patch(payload)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.building, fn {_, {{_, r}, _}} -> r == ref end) do
      nil ->
        {:noreply, state}

      {vault_id, entry} ->
        reply_waiters(entry, :error)
        {:noreply, %{state | building: Map.delete(state.building, vault_id)}}
    end
  end

  def handle_info(:sweep, state) do
    cutoff = now() - @idle_ms

    for {vault_id, user_id, _, _, used} <- :ets.tab2list(@table),
        used < cutoff,
        do: drop(vault_id, user_id)

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp patch(%{"vault_id" => vault_id, "event_type" => type, "id" => id} = p) do
    with [{_, _, handle, _, _}] <- :ets.lookup(@table, vault_id),
         {:ok, raw} <- Ecto.UUID.dump(id) do
      case type do
        "upsert" -> Native.name_index_put(handle, raw, p["path"] || "", p["title"] || "")
        "delete" -> Native.name_index_delete(handle, raw, p["path"] || "")
        _ -> :ok
      end
    end
  end

  defp patch(_payload), do: :ok

  defp reply_waiters(nil, _reply), do: :ok

  defp reply_waiters({{_pid, ref}, waiters}, reply) do
    Process.demonitor(ref, [:flush])
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  # LRU down to the cap. ponytail: approx bytes from the build; patches drift
  # it slightly, which a cap this coarse tolerates.
  defp enforce_cap do
    entries = :ets.tab2list(@table)
    total = Enum.reduce(entries, 0, fn {_, _, _, b, _}, acc -> acc + b end)

    if total > @max_bytes do
      _left =
        entries
        |> Enum.sort_by(&elem(&1, 4))
        |> Enum.reduce_while(total, fn {vault_id, user_id, _, b, _}, left ->
          drop(vault_id, user_id)
          if left - b > @max_bytes, do: {:cont, left - b}, else: {:halt, left - b}
        end)
    end

    :ok
  end

  # The handle's native memory is freed once no process references it.
  defp drop(vault_id, user_id) do
    :ets.delete(@table, vault_id)
    Phoenix.PubSub.unsubscribe(Engram.PubSub, topic(user_id, vault_id))
  end

  defp topic(user_id, vault_id), do: "sync:#{user_id}:#{vault_id}"
  defp now, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
