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

  ## Scope `"created"`: the bulk-create exception (prod 2026-10-17)

  It did become the bottleneck: a 10k-note first sync ran 10k of these, and
  worker CPU went to per-job round trips rather than the rebind itself. The
  CREATE legs (`Notes.upsert_note/4` and CRDT genesis) therefore enqueue
  `new_for_created/3` instead: one pending job per VAULT, unique while
  `:available`/`:scheduled`, scheduled `:link_rebind_delay_seconds` (default
  5 s) out. When it runs it re-resolves every basename of every live note
  in the vault whose `seq` is at or past its `from_seq`, in ONE
  `Links.bind_danglers_for_hmacs/3` pass. That is the same per-basename work
  (bound edges included, so a shorter-path newcomer still steals), just for
  every note the burst created at once rather than one job each, and a lone
  create still touches only its own basename (plus any note edited in the
  same few seconds). Rename, delete and resurrect keep the per-basename job:
  their old basename is not discoverable from live rows.

  Correctness rests on `from_seq` covering every note that collapses into a
  pending job. `vaults.change_seq` is bumped under the vault row lock, so seq
  order is commit order, but a create can still reach the enqueue after a
  newer create already opened the job. `enqueue_created/4` checks the job it
  collapsed into and falls back to a per-basename job when that job starts
  past the note, or when Oban could not take the unique lock and inserted
  nothing.

  A single create's rebind now runs up to the delay later than before.

  Args carry `basename_hmac` (base64), not plaintext `basename_key` — see
  encryption tier-3 audit T3.2 / H3. Plaintext in `oban_jobs.args` JSONB
  defeats Phase B at-rest encryption for the duration of any in-flight or
  recently-completed job. Every enqueue site computes the hmac via
  `Links.basename_hmac/2` from plaintext it already has in scope.
  """

  use Oban.Worker, queue: :indexing, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Notes.Enqueue
  alias Engram.Notes.Note
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

  @created "created"

  @doc """
  The vault-scoped bulk-create job (see "Scope `created`" above). `from_seq`
  is the created note's `seq`.
  """
  @spec new_for_created(binary(), binary(), non_neg_integer()) :: Ecto.Changeset.t()
  def new_for_created(user_id, vault_id, from_seq) when is_integer(from_seq) do
    # `unique:` at call time, not in `use`, for the reason ExtractNoteLinks
    # documents (Oban warns on a static states list short of :incomplete).
    # `scope` is in the keys so a pending per-basename job (no `scope` arg)
    # can never be taken for this one.
    opts = [
      unique: [period: :infinity, keys: [:vault_id, :scope], states: [:available, :scheduled]]
    ]

    opts =
      case rebind_delay_seconds() do
        0 -> opts
        delay -> Keyword.put(opts, :schedule_in, delay)
      end

    new(%{user_id: user_id, vault_id: vault_id, scope: @created, from_seq: from_seq}, opts)
  end

  @doc """
  Enqueues the rebind owed to a just-created note. Call it AFTER the note's
  transaction commits: a pending job that started its scan before the commit
  would miss the row.
  """
  @spec enqueue_created(binary(), binary(), non_neg_integer(), binary() | nil) ::
          {:ok, term()} | {:error, term()}
  def enqueue_created(user_id, vault_id, seq, basename_hmac) do
    case Enqueue.enqueue(new_for_created(user_id, vault_id, seq), "rebind_note_links") do
      # Collapsed into a pending job that will scan this note: done.
      {:ok, %Oban.Job{conflict?: true, id: id, args: %{"from_seq" => from}}}
      when is_integer(id) and from <= seq ->
        {:ok, :collapsed}

      # Collapsed into a job that starts past this note, or the unique lock
      # was busy and nothing was inserted (`id: nil`): rebind on our own.
      {:ok, %Oban.Job{conflict?: true}} ->
        Enqueue.enqueue(new_for(user_id, vault_id, basename_hmac), "rebind_note_links")

      other ->
        other
    end
  end

  defp rebind_delay_seconds, do: Application.get_env(:engram, :link_rebind_delay_seconds, 5)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "user_id" => user_id,
          "vault_id" => vault_id,
          "scope" => @created,
          "from_seq" => from_seq
        }
      }) do
    :ok = BackgroundPriority.demote()

    with_user_and_vault(user_id, vault_id, fn user, vault ->
      Links.bind_danglers_for_hmacs(user, vault, created_hmacs(user_id, vault_id, from_seq))
    end)
  end

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
        with_user_and_vault(user_id, vault_id, fn user, vault ->
          Links.bind_danglers_for_hmac(user, vault, basename_hmac)
        end)

      :error ->
        {:discard, "invalid basename_hmac base64"}
    end
  end

  # Basenames of every live note changed at or past `from_seq`; served by the
  # (vault_id, seq, id) index.
  defp created_hmacs(user_id, vault_id, from_seq) do
    Repo.with_tenant!(user_id, fn ->
      Repo.all(
        from(n in Note,
          where:
            n.user_id == ^user_id and n.vault_id == ^vault_id and n.seq >= ^from_seq and
              n.kind == "note" and
              is_nil(n.deleted_at) and not is_nil(n.basename_hmac),
          distinct: true,
          select: n.basename_hmac
        )
      )
    end)
  end

  defp with_user_and_vault(user_id, vault_id, fun) do
    case RotationGate.check(user_id) do
      :ok ->
        user = Accounts.get_user!(user_id)

        # `vaults` carries FORCE ROW LEVEL SECURITY. Unscoped, this read
        # returns nil under any role without BYPASSRLS and the job
        # discards with "vault not found", observed on staging the moment
        # the app pool dropped to `engram_app`, for a vault that plainly
        # exists. `user_id` is already in the job args (used just above),
        # so there is no tenant to discover here.
        #
        # `skip_tenant_check` deliberately dropped rather than kept
        # alongside the scope: inside `with_tenant/2` the guard passes on
        # the process-dict tenant anyway, and leaving the option would
        # silence `Engram.TenantError` if this read were ever hoisted back
        # out of the closure.
        #
        # `bind_danglers_for_hmac/3` opens its own scope and is called
        # OUTSIDE this block. That costs a second `set_config` round trip
        # (re-entrancy is free only INSIDE an active `with_tenant`, and
        # this block has already exited), which is the right trade: the
        # vault load does not hold a transaction across the per-edge
        # rebind loop.
        case Repo.with_tenant(user_id, fn -> Repo.get(Vault, vault_id) end) do
          {:ok, nil} -> {:discard, "vault #{vault_id} not found"}
          {:ok, %Vault{} = vault} -> fun.(user, vault)
        end

      {:error, :rotation_in_progress} ->
        {:snooze, 60}

      {:error, :user_not_found} ->
        {:discard, :user_deleted}
    end
  end
end
