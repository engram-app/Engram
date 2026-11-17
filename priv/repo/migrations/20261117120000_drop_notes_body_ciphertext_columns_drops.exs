# safety_assured: "lib/ names :content_ciphertext and :crdt_state_ciphertext only as virtual Note fields that NoteBody maps to note_bodies.content_ct / crdt_ct; no query selects or writes the notes columns since R8(d) (#2513, in 0.87.0, the rollback floor)"

# Shared with 20261111000000; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.DropNotesBodyCiphertextColumnsDrops do
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R8(e): drops `notes.content_ciphertext` and `notes.crdt_state_ciphertext`.
  Every body lives in `note_bodies` (R8(c), 20261107120000, and its heal
  20261110130000, both earlier in any batch). No release from R8(b2) writes
  the columns, and from R8(d) (0.87.0, the rollback floor) nothing in the
  database or the app names them, so N-1 and a rollback to the floor are
  unaffected. `content_nonce` and `crdt_state_nonce` stay (write fences).

  Gate, before the drop (#2402): no `kind = 'note'` row may lack its body
  row (same owner), or have a NULL body column while its `notes` column
  still holds the only copy. NULL tests only, so no TOAST read; one
  anti-join over `notes` on the `note_bodies` primary key. A non-zero count
  raises with the count and leaves the version unrecorded, so the columns
  stay. The gate must see every tenant (FORCE RLS on both tables): as a
  superuser/BYPASSRLS role, else as `engram_maintenance` (its
  `maintenance_all` policies), else one tenanted query per user. On the two
  one-statement paths the connection must see a note when the table's
  statistics say it has any, so an RLS-blind 0 cannot pass.

  The drop is one statement (both columns or neither), a catalog change
  with no rewrite, under LockTimeoutRetry's 5 s `lock_timeout` retried
  twice. Rerun-safe: with the columns gone the gate is skipped and IF
  EXISTS makes the drop a no-op. The dead bytes stay in the TOAST relation
  until vacuum reuses them; nothing here reclaims disk. Calls no app module.

  `down` restores the two columns, nullable and empty, with their
  20261021090600 storage. Nothing reads them, so there is nothing to refill.
  """

  @lock_timeout "5s"
  @statement_timeout "120s"

  @columns_present """
  SELECT count(*) FROM pg_attribute
  WHERE attrelid = 'notes'::regclass AND NOT attisdropped
    AND attname IN ('content_ciphertext', 'crdt_state_ciphertext')
  """

  @unsafe_where """
  n.kind = 'note'
    AND (b.note_id IS NULL
      OR (b.content_ct IS NULL AND n.content_ciphertext IS NOT NULL)
      OR (b.crdt_ct IS NULL AND n.crdt_state_ciphertext IS NOT NULL))
  """

  @unsafe_all """
  SELECT count(*) FILTER (WHERE #{@unsafe_where}), count(*)
  FROM notes n
  LEFT JOIN note_bodies b ON b.note_id = n.id AND b.user_id = n.user_id
  """

  @unsafe_user """
  SELECT count(*) FROM notes n
  LEFT JOIN note_bodies b ON b.note_id = n.id AND b.user_id = n.user_id
  WHERE n.user_id = $1 AND #{@unsafe_where}
  """

  # As 20261107120000's: bypass, or a usable `engram_maintenance`.
  @visibility """
  SELECT
    (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user),
    CASE WHEN to_regrole('engram_maintenance') IS NULL THEN false
      ELSE pg_has_role('engram_maintenance', 'SET')
        AND has_table_privilege('engram_maintenance', 'notes', 'SELECT')
        AND has_table_privilege('engram_maintenance', 'note_bodies', 'SELECT')
        AND (SELECT count(*) = 2 FROM pg_policy
             WHERE polname = 'maintenance_all'
               AND polrelid IN ('notes'::regclass, 'note_bodies'::regclass))
    END
  """

  @live_estimate "SELECT coalesce(n_live_tup, 0) FROM pg_stat_user_tables WHERE relid = 'notes'::regclass"

  def up, do: run_up(repo())
  def down, do: run_down(repo())

  @doc false
  # Public for `DropNotesBodyCiphertextColumnsTest`.
  def run_up(repo) do
    if columns_present?(repo), do: gate!(repo)

    LockTimeoutRetry.with_lock_timeout(repo, [
      "ALTER TABLE notes DROP COLUMN IF EXISTS content_ciphertext, " <>
        "DROP COLUMN IF EXISTS crdt_state_ciphertext"
    ])
  end

  @doc false
  def run_down(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, [
      "ALTER TABLE notes ADD COLUMN IF NOT EXISTS content_ciphertext bytea, " <>
        "ADD COLUMN IF NOT EXISTS crdt_state_ciphertext bytea",
      "ALTER TABLE notes ALTER COLUMN content_ciphertext SET STORAGE EXTERNAL, " <>
        "ALTER COLUMN crdt_state_ciphertext SET STORAGE EXTERNAL"
    ])
  end

  defp columns_present?(repo),
    do: match?(%{rows: [[n]]} when n > 0, repo.query!(@columns_present))

  @doc false
  # Public for the test: the count of notes the drop would lose. Raises
  # when the connection cannot be shown to see every tenant.
  def unsafe_count(repo) do
    case repo.query!(@visibility).rows do
      [[true, _]] -> in_txn(repo, nil, fn -> visible_count!(repo) end)
      [[_, true]] -> in_txn(repo, "engram_maintenance", fn -> visible_count!(repo) end)
      _ -> per_user_count(repo)
    end
  end

  defp gate!(repo) do
    case unsafe_count(repo) do
      0 ->
        :ok

      n ->
        raise "notes body columns drop: #{n} note(s) hold their only body copy in " <>
                "notes (no body row, or a NULL body column); not dropping, not recording"
    end
  end

  defp visible_count!(repo) do
    %{rows: [[unsafe, seen]]} = repo.query!(@unsafe_all)

    if seen == 0 and live_estimate(repo) > 0,
      do: raise("notes body columns drop: the gate sees no notes but notes has rows (RLS)")

    unsafe
  end

  defp live_estimate(repo) do
    case repo.query!(@live_estimate).rows do
      [[n]] -> n
      _ -> 0
    end
  end

  defp per_user_count(repo) do
    %{rows: users} = repo.query!("SELECT id FROM users ORDER BY id")

    Enum.reduce(users, 0, fn [user_id], acc ->
      acc +
        in_txn(repo, nil, fn ->
          repo.query!("SELECT set_config('app.current_tenant', $1::uuid::text, true)", [user_id])
          %{rows: [[n]]} = repo.query!(@unsafe_user, [user_id])
          repo.query!("SELECT set_config('app.current_tenant', '', true)")
          n
        end)
    end)
  end

  # Role and tenant are cleared before the transaction ends (a test runs
  # this inside a sandbox transaction, where LOCAL would outlive a savepoint).
  defp in_txn(repo, role, fun) do
    {:ok, result} =
      repo.transaction(
        fn ->
          repo.query!(
            "SELECT set_config('lock_timeout', '#{@lock_timeout}', true), " <>
              "set_config('statement_timeout', '#{@statement_timeout}', true)"
          )

          if role, do: repo.query!("SET LOCAL ROLE #{role}")
          result = fun.()
          if role, do: repo.query!("SELECT set_config('role', 'none', true)")
          result
        end,
        timeout: :infinity
      )

    result
  end
end
