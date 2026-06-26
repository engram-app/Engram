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

  @sup Engram.Notes.CrdtDocSupervisor

  @doc "The `:global` registration name for a note's doc room."
  @spec global_name(String.t()) :: {:global, {:crdt_doc, String.t()}}
  def global_name(note_id) when is_binary(note_id), do: {:global, {:crdt_doc, note_id}}

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
end
