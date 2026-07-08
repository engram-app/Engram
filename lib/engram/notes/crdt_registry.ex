defmodule Engram.Notes.CrdtRegistry do
  @moduledoc """
  Cluster-wide singleton routing for CRDT doc rooms via `:global`.

  A given note's room lives on exactly one node; `:global` name registration
  enforces the single-owner invariant across the (live, 2026-06-23) BEAM
  cluster. Rooms are ephemeral and rebuildable from Postgres, so a node loss
  simply drops the room — clients re-establish it on reconnect via sync step1
  (no Horde handoff needed; ephemeral rooms don't benefit from it).

  Rooms are started under `Engram.Notes.CrdtDocSupervisor` (a
  `DynamicSupervisor` wired in `Engram.Application`).
  """

  alias Yex.Sync.SharedDoc

  @sup Engram.Notes.CrdtDocSupervisor

  # The singleton room has `auto_exit: true`, so it stops when its last observer
  # leaves. `:global.whereis_name` can hand back a room that is mid-termination,
  # so a plain `observe/1` GenServer.call would exit and crash the caller. Retry
  # a bounded number of times, yielding so `:global` drops the dead registration
  # and a fresh room is started on the next attempt.
  @observe_attempts 5
  @observe_retry_delay_ms 5

  @doc "The `:global` registration name for a note's doc room."
  @spec global_name(String.t()) :: {:global, {:crdt_doc, String.t()}}
  def global_name(note_id) when is_binary(note_id), do: {:global, {:crdt_doc, note_id}}

  @doc """
  Find the live room for `note_id` WITHOUT starting one, returning `nil` when
  no room is running anywhere in the cluster. Used by the deliver-out path,
  which must never spin a room for a note nobody is observing.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(note_id) when is_binary(note_id) do
    case :global.whereis_name({:crdt_doc, note_id}) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  @doc """
  Terminate a note's live room WITHOUT running its unbind checkpoint:
  unregister the :global name first (so lookups stop resolving to the dying
  pid — NOTE: :global registration uses the INNER term `{:crdt_doc, id}`, not
  the `{:global, …}` wrapper `global_name/1` returns for GenServer `name:`),
  then a brutal `:kill` (untrappable, skips terminate → unbind → checkpoint).
  Safe on dead/absent rooms (both steps are idempotent no-ops). Used by the
  deliver-out quarantine (a room that failed to converge must not persist)
  and vault deletion (a room must not outlive its vault, #954). Nothing is
  lost: every room update is already in the durable tail-log.
  """
  @spec terminate_room(String.t()) :: :ok
  def terminate_room(note_id) when is_binary(note_id) do
    case :global.whereis_name({:crdt_doc, note_id}) do
      :undefined ->
        :ok

      pid when is_pid(pid) ->
        _ = :global.unregister_name({:crdt_doc, note_id})
        Process.exit(pid, :kill)
        :ok
    end
  end

  @doc """
  Idempotently start (or find) the singleton room for `note_id`.

  Returns `{:ok, pid}` whether the room was just started or was already
  running on any node in the cluster.
  """
  @spec ensure_started(String.t(), String.t(), String.t()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(user_id, vault_id, note_id) do
    case :global.whereis_name({:crdt_doc, note_id}) do
      pid when is_pid(pid) ->
        {:ok, pid}

      :undefined ->
        spec = {Engram.Notes.CrdtDoc, [note_id: note_id, user_id: user_id, vault_id: vault_id]}

        case DynamicSupervisor.start_child(@sup, spec) do
          {:ok, pid} -> {:ok, pid}
          # Lost the cluster-wide race — another node registered first.
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Ensure the singleton room for `note_id` is started AND observed by the
  CALLING process, recovering from the auto-exit race.

  Must be called from the process that should receive `{:yjs, frame, room}`
  broadcasts (the channel), since `SharedDoc.observe/1` registers `self()`.
  Returns `{:error, :room_unavailable}` if the room keeps auto-exiting across
  every attempt.
  """
  @spec ensure_observed(String.t(), String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_observed(user_id, vault_id, note_id) do
    observe_with_retry(
      fn -> ensure_started(user_id, vault_id, note_id) end,
      fn room -> SharedDoc.observe(room) end
    )
  end

  @doc """
  Retry helper backing `ensure_observed/3`. Calls `start_fun` to obtain a room,
  then `observe_fun` on it; if `observe_fun` exits (the room auto-exited mid
  race), yields and retries with a freshly obtained room. Extracted so the
  retry logic is testable with injected functions.
  """
  @spec observe_with_retry((-> {:ok, room} | {:error, term()}), (room -> :ok), pos_integer()) ::
          {:ok, room} | {:error, term()}
        when room: term()
  def observe_with_retry(start_fun, observe_fun, attempts \\ @observe_attempts)

  def observe_with_retry(_start_fun, _observe_fun, attempts) when attempts <= 0 do
    {:error, :room_unavailable}
  end

  def observe_with_retry(start_fun, observe_fun, attempts) do
    with {:ok, room} <- start_fun.() do
      try do
        :ok = observe_fun.(room)
        {:ok, room}
      catch
        :exit, _reason ->
          Process.sleep(@observe_retry_delay_ms)
          observe_with_retry(start_fun, observe_fun, attempts - 1)
      end
    end
  end
end
