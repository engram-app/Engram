defmodule Engram.Workers.RebindNoteLinks do
  @moduledoc """
  Oban worker: re-resolves every link edge (dangling or currently bound)
  whose target basename matches `basename_key`, via `Links.bind_danglers_for/3`.

  Enqueued whenever a note write might give a dangling (or wrongly-bound)
  edge something new to resolve against: `Notes.upsert_note/4` on CREATE,
  `Notes.rename_note/4` on both the old and new basename (the old name's
  remaining candidates must re-resolve too), note resurrection, and
  (chained from `DeleteNoteIndex`) note deletion — a delete can un-shadow a
  shorter-path sibling that was losing the resolution tiebreak.
  """

  use Oban.Worker, queue: :indexing, max_attempts: 3

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @doc "Builds a rebind job for `basename_key` within `vault_id`."
  def new_for(user_id, vault_id, basename_key) do
    new(%{user_id: user_id, vault_id: vault_id, basename_key: basename_key})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "vault_id" => vault_id, "basename_key" => basename_key}
      }) do
    case RotationGate.check(user_id) do
      :ok ->
        user = Accounts.get_user!(user_id)

        case Repo.get(Vault, vault_id, skip_tenant_check: true) do
          nil -> {:discard, "vault #{vault_id} not found"}
          %Vault{} = vault -> Links.bind_danglers_for(user, vault, basename_key)
        end

      {:error, :rotation_in_progress} ->
        {:snooze, 60}

      {:error, :user_not_found} ->
        {:discard, :user_deleted}
    end
  end
end
