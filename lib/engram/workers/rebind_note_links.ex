defmodule Engram.Workers.RebindNoteLinks do
  @moduledoc """
  Oban worker: re-resolves every link edge (dangling or currently bound)
  whose target basename hmac matches `basename_hmac`, via
  `Links.bind_danglers_for_hmac/3`.

  Enqueued whenever a note or attachment write might give a dangling (or
  wrongly-bound) edge something new to resolve against: `Notes.upsert_note/4`
  on CREATE, `Notes.rename_note/4` on both the old and new basename (the old
  name's remaining candidates must re-resolve too), note resurrection, and
  (chained from `DeleteNoteIndex`) note deletion — a delete can un-shadow a
  shorter-path sibling that was losing the resolution tiebreak.

  ## Why this stays per-basename, and carries no `unique`

  A bulk import enqueues one job per created note — 1,700 notes, 1,700
  DISTINCT basenames — so neither available lever helps that shape:

  * **Per-vault coalescing** would collapse the import to one job, and regress
    the common case badly: a lone note create in a 10k-note vault would
    re-resolve every edge in the vault instead of the handful sharing one
    basename. The per-basename job is already cheap when a new note has no
    inbound references yet — one indexed lookup on `note_links_basename_idx`
    and out.
  * **`unique` on `[:vault_id, :basename_hmac]`** collapses nothing during an
    import (distinct basenames) while silently swallowing the folder-rename
    fan-out against still-pending create jobs. `rewrite_wiring_test.exs`
    fences that fan-out and rightly failed when this was tried on 2026-08-20.

  If this job ever does become the bottleneck, the lever is queue concurrency
  or the `:low` priority demote below — not deduplication.

  Args carry `basename_hmac` (base64), not plaintext `basename_key` — see
  encryption tier-3 audit T3.2 / H3. Plaintext in `oban_jobs.args` JSONB
  defeats Phase B at-rest encryption for the duration of any in-flight or
  recently-completed job. Every enqueue site computes the hmac via
  `Links.basename_hmac/2` from plaintext it already has in scope.
  """

  use Oban.Worker, queue: :indexing, max_attempts: 3

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.BackgroundPriority

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc """
  Builds a rebind job for the raw `basename_hmac` bytes within `vault_id`.

  A `nil` hmac (legacy pre-backfill rows) returns `:skip` — no link edge can
  reference a basename hmac the row never had, so there is nothing to rebind.
  `Enqueue.enqueue/3` no-ops on `:skip`, keeping every enqueue site safe
  without per-caller guards (incident 2026-08-12: `Base.encode64(nil)` here
  500'd attachment deletes AFTER the soft-delete had committed, #1369).
  """
  @spec new_for(binary(), binary(), binary() | nil) :: Ecto.Changeset.t() | :skip
  def new_for(_user_id, _vault_id, nil), do: :skip

  def new_for(user_id, vault_id, basename_hmac) do
    new(%{user_id: user_id, vault_id: vault_id, basename_hmac: Base.encode64(basename_hmac)})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "user_id" => user_id,
          "vault_id" => vault_id,
          "basename_hmac" => basename_hmac_b64
        }
      }) do
    :ok = BackgroundPriority.demote()

    case Base.decode64(basename_hmac_b64) do
      {:ok, basename_hmac} ->
        case RotationGate.check(user_id) do
          :ok ->
            user = Accounts.get_user!(user_id)

            case Repo.get(Vault, vault_id, skip_tenant_check: true) do
              nil -> {:discard, "vault #{vault_id} not found"}
              %Vault{} = vault -> Links.bind_danglers_for_hmac(user, vault, basename_hmac)
            end

          {:error, :rotation_in_progress} ->
            {:snooze, 60}

          {:error, :user_not_found} ->
            {:discard, :user_deleted}
        end

      :error ->
        {:discard, "invalid basename_hmac base64"}
    end
  end
end
