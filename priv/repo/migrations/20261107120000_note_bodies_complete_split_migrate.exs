defmodule Engram.Repo.Migrations.NoteBodiesCompleteSplitMigrate do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R8(c) migrate-data: gives every note a `note_bodies` row before the app
  boots, so readers need no fallback to the `notes` body columns (which
  R8(d) drops).

  A note with no body row was written before `notes_sync_body`
  (20261021110200) and not yet reached by the `NoteSplit` ledger. Until this
  release the read fell back to the `notes` columns and `NoteSplit` inserted
  the row hourly. This release removes both, so a self-hoster who jumps
  from a pre-split release must have every body row by the time the first
  request is served: a migration, which runs before boot.

  The insert is the one `NoteBody.sync!/3` ran for `NoteSplit` (a missing
  row inserted whole), the same SQL text: the raw `notes` ciphertext and
  nonce bytes concatenated into the trigger's merged layout, the head
  decoded, nothing decrypted. It also seeds the note's narrow sizes
  (`note_index_state`) from the values the `note_bodies_sizes` BEFORE
  trigger computed, as that insert did. `ON CONFLICT DO NOTHING`: a body
  row a writer inserted meanwhile (a 0.78 node during a rolling deploy) is
  newer and is kept.

  Per user, inside that user's RLS context (`app.current_tenant`, one
  transaction per window), in id windows of #{1_000}: the migrator owns the
  tables but under FORCE RLS sees no row without a tenant, and the tenant
  policy has no `TO` clause, so it applies to the owner too. No table lock
  is taken (the `NO FORCE` pattern would hold ACCESS EXCLUSIVE on `notes`
  for every window). Each user's walk ends with a check in the same
  context. The insert takes every `kind = 'note'` row of the user,
  tombstones and NULL-nonce rows included (their envelopes, NULL or merged,
  copied as they are); folder rows have no body.

  The one row it skips is a note whose body row exists under another owner
  (drift: hand-edited SQL or a restore; no code path writes one): the
  tenant policy hides it and ON CONFLICT keeps it, every read joins on the
  owner (so the note reads with a NULL body), and every write fails RLS.
  Nothing else heals it, so the check repairs it: for those notes only, in
  one transaction with `note_bodies` under `NO FORCE ROW LEVEL SECURITY`
  (the documented bypass; ACCESS EXCLUSIVE on `note_bodies`, restored by
  FORCE or the rollback), a note whose `notes` copy is present (the null
  batch never clears such a row) gets its body rebuilt from that copy, as
  the insert builds it (the CRDT state kept when the copy has none), and a
  note without one gets its body row handed back to its owner, with a
  warning that the bytes may not decrypt. A note's envelopes are bound to
  its own id (AAD) and its owner's key, so bytes written for it decrypt
  once the row is the owner's again. A note still unreadable after that
  logs a warning. Never a raise: a raising migration blocks every boot
  (zero operator action).

  Prod (2026-11-07): 0 notes without a body row and 0 body rows under
  another owner, so it inserts nothing, takes no table lock, and reads each
  user's note ids twice (the walk and the check). Rerun-safe; no `down` work (the rows
  are what every release from 0.76 on writes). Calls no app module.
  """

  require Logger

  @window 1_000

  # The merged layout of one `notes` (ciphertext, nonce) pair, as
  # `NoteBody` built it (from the dropped `notes_sync_body` trigger).
  merged = fn ct, nonce ->
    """
    CASE WHEN n.#{ct} IS NULL THEN NULL
        WHEN n.#{nonce} IS NULL THEN n.#{ct}
        WHEN length(n.#{nonce}) = 13 THEN n.#{nonce} || n.#{ct}
        ELSE '\\x00'::bytea || n.#{nonce} || n.#{ct} END
    """
  end

  @insert """
  WITH w AS (
    SELECT id FROM notes WHERE user_id = $1 AND id > $2 ORDER BY id LIMIT #{@window}
  ), ins AS (
    INSERT INTO note_bodies (note_id, user_id, key_version, content_ct, crdt_ct, crdt_head)
      SELECT n.id, n.user_id,
        CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END,
        #{merged.("content_ciphertext", "content_nonce")},
        #{merged.("crdt_state_ciphertext", "crdt_state_nonce")},
        CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$'
          THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END
      FROM notes n JOIN w ON w.id = n.id
      WHERE n.kind = 'note'
        AND NOT EXISTS (SELECT 1 FROM note_bodies x WHERE x.note_id = n.id)
    ON CONFLICT (note_id) DO NOTHING
    RETURNING note_id, content_bytes, state_bytes
  ), sized AS (
    UPDATE note_index_state s SET
      content_bytes = i.content_bytes,
      state_bytes = i.state_bytes,
      has_state = i.state_bytes IS NOT NULL
    FROM ins i
    WHERE s.note_id = i.note_id
  )
  SELECT (SELECT id FROM w ORDER BY id DESC LIMIT 1), (SELECT count(*) FROM ins)::int
  """

  # Notes of the user that read with no body: no body row of the same
  # owner (`NoteBody.join/1` matches the owner too). The same answer with or
  # without RLS bypass.
  @left """
  SELECT n.id FROM notes n
  WHERE n.user_id = $1 AND n.kind = 'note'
    AND NOT EXISTS (SELECT 1 FROM note_bodies x WHERE x.note_id = n.id AND x.user_id = n.user_id)
  ORDER BY n.id LIMIT #{@window}
  """

  # The repair, RLS bypassed on `note_bodies`: rebuild from the `notes`
  # copy where it is present, else hand the row back to the owner.
  @from_copy """
  INSERT INTO note_bodies (note_id, user_id, key_version, content_ct, crdt_ct, crdt_head)
    SELECT n.id, n.user_id,
      CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END,
      #{merged.("content_ciphertext", "content_nonce")},
      #{merged.("crdt_state_ciphertext", "crdt_state_nonce")},
      CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$'
        THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END
    FROM notes n
    WHERE n.id = ANY($1::uuid[]) AND n.user_id = $2 AND n.kind = 'note'
      AND n.content_ciphertext IS NOT NULL
  ON CONFLICT (note_id) DO UPDATE SET
    user_id = EXCLUDED.user_id,
    key_version = EXCLUDED.key_version,
    content_ct = EXCLUDED.content_ct,
    crdt_ct = COALESCE(EXCLUDED.crdt_ct, note_bodies.crdt_ct),
    crdt_head = EXCLUDED.crdt_head
  """

  @to_owner """
  UPDATE note_bodies b SET
    user_id = n.user_id,
    key_version = CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END
  FROM notes n
  WHERE b.note_id = n.id AND n.id = ANY($1::uuid[]) AND n.user_id = $2
    AND b.user_id <> n.user_id
  RETURNING b.note_id::text
  """

  def up, do: complete_split(repo())

  def down, do: :ok

  @doc false
  # The whole migration on `repo`; public for `SelfHostJumpTest`.
  def complete_split(repo) do
    repo.checkout(fn ->
      repo.query!("SET lock_timeout = '5s'")

      try do
        %{rows: users} = repo.query!("SELECT id FROM users ORDER BY id")
        Enum.each(users, fn [user_id] -> user!(repo, user_id) end)
      after
        repo.query!("RESET lock_timeout")
      end
    end)
  end

  defp user!(repo, user_id) do
    walk(repo, user_id, <<0::128>>)

    case left(repo, user_id) do
      [] ->
        :ok

      ids ->
        repair(repo, user_id, ids)

        # A warning, never a raise: a raising migration blocks every boot.
        with [_ | _] = still <- left(repo, user_id) do
          Logger.warning("note_bodies split incomplete: notes still read with no body",
            user_id: Ecto.UUID.load!(user_id),
            note_ids: Enum.map(still, &Ecto.UUID.load!/1)
          )
        end
    end
  end

  defp left(repo, user_id) do
    tenant(repo, user_id, fn -> Enum.map(repo.query!(@left, [user_id]).rows, &hd/1) end)
  end

  # Only for a user with a note under a foreign body row (prod: none).
  defp repair(repo, user_id, ids) do
    handed_back =
      tenant(repo, user_id, fn ->
        repo.query!("ALTER TABLE note_bodies NO FORCE ROW LEVEL SECURITY")
        repo.query!(@from_copy, [ids, user_id])
        %{rows: rows} = repo.query!(@to_owner, [ids, user_id])
        repo.query!("ALTER TABLE note_bodies FORCE ROW LEVEL SECURITY")
        Enum.map(rows, &hd/1)
      end)

    if handed_back != [] do
      Logger.warning(
        "note_bodies split: body rows handed back to their owner, no notes copy; the bytes may not decrypt",
        user_id: Ecto.UUID.load!(user_id),
        note_ids: handed_back
      )
    end
  end

  defp walk(repo, user_id, after_id) do
    case tenant(repo, user_id, fn -> repo.query!(@insert, [user_id, after_id]).rows end) do
      [[nil, _]] -> :ok
      [[last, _]] -> walk(repo, user_id, last)
    end
  end

  # One transaction in `user_id`'s RLS context; the tenant is cleared before
  # it ends (a test runs this in a sandbox, where it would outlive a
  # savepoint).
  defp tenant(repo, user_id, fun) do
    {:ok, result} =
      repo.transaction(fn ->
        repo.query!("SELECT set_config('app.current_tenant', $1::uuid::text, true)", [user_id])

        result = fun.()
        repo.query!("SELECT set_config('app.current_tenant', '', true)")
        result
      end)

    result
  end
end
