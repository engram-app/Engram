defmodule Engram.Notes.CrdtIndexRegistry do
  @moduledoc """
  Cluster-wide singleton routing for per-vault INDEX rooms (#1150), mirroring
  `Engram.Notes.CrdtRegistry` for notes.

  A vault's index room lives on exactly one node; `:global` enforces the
  single-owner invariant across the cluster (live since 2026-06-23). Rooms are
  ephemeral — a node loss simply drops the room and clients re-establish it via
  sync step1.

  Retry logic is NOT duplicated from `CrdtRegistry`: `observe_with_retry/3` is
  already public and takes injected functions precisely so a second room type
  can reuse it. The auto-exit race it guards is identical here — `:global`
  can hand back a room that is mid-termination, and a plain `observe/1` call
  would exit the caller.
  """

  alias Engram.Notes.{CrdtIndexDoc, CrdtRegistry}
  alias Yex.Sync.SharedDoc

  @sup Engram.Notes.CrdtDocSupervisor

  @doc "The `:global` registration name for a vault's index room."
  @spec global_name(String.t()) :: {:global, {:crdt_index, String.t()}}
  def global_name(vault_id) when is_binary(vault_id), do: {:global, {:crdt_index, vault_id}}

  @doc """
  Find the live index room for `vault_id` WITHOUT starting one, or `nil`.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(vault_id) when is_binary(vault_id) do
    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  @doc """
  Idempotently start (or find) the singleton index room for `vault_id`.
  """
  @spec ensure_started(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(user_id, vault_id) do
    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) ->
        {:ok, pid}

      :undefined ->
        spec = {CrdtIndexDoc, [vault_id: vault_id, user_id: user_id]}

        case DynamicSupervisor.start_child(@sup, spec) do
          {:ok, pid} -> {:ok, pid}
          # Lost the cluster-wide race — another node registered first.
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Ensure the index room is started AND observed by the CALLING process,
  recovering from the auto-exit race. Must be called from the process that
  should receive `{:yjs, frame, room}` (the channel), since `observe/1`
  registers `self()`.
  """
  @spec ensure_observed(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_observed(user_id, vault_id) do
    CrdtRegistry.observe_with_retry(
      fn -> ensure_started(user_id, vault_id) end,
      fn room -> SharedDoc.observe(room) end
    )
  end
end
