defmodule Engram.DataMigrations do
  @moduledoc """
  Completion ledger for self-healing data migrations. See
  `docs/context/data-migrations-ledger.md`.

  A migration is done for `version` when its row holds that version or a
  higher one (a rollback to older code must not redo newer work) and
  `completed_at` is set. Bumping the version in code reopens it.

  The ledger only saves work: every reader must still handle rows in any
  older format, so a row an old node writes after `mark_done/2` is readable
  and the next version bump picks it up.
  """
  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.DataMigrations.Entry
  alias Engram.Repo

  @in_flight ~w(available scheduled executing retryable)

  @spec done?(String.t(), pos_integer()) :: boolean()
  def done?(name, version) do
    # Only `true` is cached: done goes back to not-done only through a code
    # change (which restarts the node) or `reopen/2` (which drops this node's
    # entry; other nodes keep theirs until restart).
    case :persistent_term.get({__MODULE__, name, version}, false) do
      true ->
        true

      false ->
        done =
          Repo.exists?(
            from(e in Entry,
              where: e.name == ^name and e.version >= ^version and not is_nil(e.completed_at)
            )
          )

        if done, do: :persistent_term.put({__MODULE__, name, version}, true)
        done
    end
  end

  @doc """
  Marks `name` done at `version`. A no-op on a row already at a higher
  version: during a rolling deploy an old node finishing its older version
  must neither lower the version nor close the newer version's work.
  """
  @spec mark_done(String.t(), pos_integer()) :: :ok
  def mark_done(name, version) do
    now = DateTime.utc_now()

    # insert_all, not insert!: a conflict the WHERE filters out updates no row,
    # which insert! reports as a stale entry.
    {_, _} =
      Repo.insert_all(
        Entry,
        [%{name: name, version: version, completed_at: now, inserted_at: now, updated_at: now}],
        on_conflict:
          from(e in Entry,
            where: e.version <= ^version,
            update: [set: [version: ^version, completed_at: ^now, updated_at: ^now]]
          ),
        conflict_target: :name
      )

    :ok
  end

  @doc """
  Records that a pass left `name` unfinished and returns the row. `opened_at`
  is set on insert and whenever the work (re)opens (a higher version, or a
  row that was closed); otherwise it keeps the original first-seen time, so
  age since `opened_at` measures how long it has been stuck. The stored
  version only ever rises: an old node in a mixed-version fleet must not
  lower it, or the new node's next call would read a bump and reset the
  clock.
  """
  @spec note_open(String.t(), pos_integer()) :: struct()
  def note_open(name, version) do
    now = DateTime.utc_now()

    update =
      from(e in Entry,
        update: [
          set: [
            opened_at:
              fragment(
                "CASE WHEN ? < ? OR ? IS NOT NULL OR ? IS NULL THEN ? ELSE ? END",
                e.version,
                ^version,
                e.completed_at,
                e.opened_at,
                ^now,
                e.opened_at
              ),
            alerted_at:
              fragment(
                "CASE WHEN ? < ? OR ? IS NOT NULL OR ? IS NULL THEN NULL ELSE ? END",
                e.version,
                ^version,
                e.completed_at,
                e.opened_at,
                e.alerted_at
              ),
            version: fragment("GREATEST(?, ?)", e.version, ^version),
            completed_at: nil,
            updated_at: ^now
          ]
        ]
      )

    Repo.insert!(
      %Entry{name: name, version: version, opened_at: now},
      on_conflict: update,
      conflict_target: :name,
      returning: true
    )
  end

  @doc """
  True when `name` is done and its last verification (`completed_at`, set by
  every `mark_done/2`) is older than `cutoff`.
  """
  @spec verified_before?(String.t(), DateTime.t()) :: boolean()
  def verified_before?(name, cutoff) do
    Repo.exists?(from(e in Entry, where: e.name == ^name and e.completed_at < ^cutoff))
  end

  @doc """
  Reopens a done migration (a re-verify found work again): `note_open/2`
  clears `completed_at` and restarts the stuck clock, and this node's cached
  `done?` is dropped. Another node's cache lasts until it restarts; the runner
  only runs on the Cron leader, and its next re-verify reopens again.
  """
  @spec reopen(String.t(), pos_integer()) :: :ok
  def reopen(name, version) do
    _ = note_open(name, version)
    :persistent_term.erase({__MODULE__, name, version})
    :ok
  end

  @doc """
  Holds an OPEN row's stuck clock while its migration is disabled: resets
  `opened_at` to now and clears `alerted_at`. Never creates a row and never
  touches a done one.
  """
  @spec hold_clock(String.t()) :: :ok
  def hold_clock(name) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(e in Entry,
        where: e.name == ^name and is_nil(e.completed_at) and not is_nil(e.opened_at)
      ),
      set: [opened_at: now, alerted_at: nil, updated_at: now]
    )

    :ok
  end

  @spec mark_alerted(String.t()) :: :ok
  def mark_alerted(name) do
    now = DateTime.utc_now()
    Repo.update_all(from(e in Entry, where: e.name == ^name), set: [alerted_at: now])
    :ok
  end

  @doc """
  True if `queryable` returns a row in any tenant. Uses the maintenance repo
  when enabled (one query), else one query per user inside that user's RLS
  context, stopping at the first user with a row. Never trusts a cross-tenant
  read on the app pool, which FORCE RLS turns into zero rows (#1349).
  """
  @spec any_row?(Ecto.Queryable.t()) :: boolean()
  def any_row?(queryable) do
    case Repo.maintenance() do
      Repo ->
        Enum.any?(TenantScan.user_ids(), fn user_id ->
          {:ok, found} = Repo.with_tenant(user_id, fn -> Repo.exists?(queryable) end)
          found
        end)

      maintenance ->
        maintenance.exists?(queryable)
    end
  end

  @doc "True while any job of `worker` is queued or running."
  @spec jobs_in_flight?(module()) :: boolean()
  def jobs_in_flight?(worker) do
    name = worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
    Repo.exists?(from(j in Oban.Job, where: j.worker == ^name and j.state in @in_flight))
  end

  @doc false
  def reset_cache do
    for {{__MODULE__, _, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end
end
