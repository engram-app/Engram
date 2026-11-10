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
  FORCE or the rollback), the body row goes back to the note's owner.
  Strictly non-destructive: existing body bytes are never overwritten (a
  `notes` copy can be stale under a newer nonce, release B writes only the
  nonce, and SQL cannot tell that from a stale body); a body that does not
  match the `notes` nonce is kept and logged for a human look, and only a
  NULL body column is rebuilt from the `notes` copy, when the copy's nonce
  is set. A note's envelopes are bound to its own id (AAD) and its owner's
  key, so bytes written for it decrypt once the row is the owner's again.
  Each path is logged with the note ids; the repair repeats until the user
  has no such note, and a note still unreadable after that logs a warning.
  Never a raise: a raising migration blocks every boot (zero operator
  action).

  Prod (2026-11-07): 0 notes without a body row and 0 body rows under
  another owner, so it inserts nothing and takes no table lock. Rerun-safe;
  no `down` work (the rows are what every release from 0.76 on writes).
  Calls no app module.

  No connection is held across the walk: each window is its own short
  transaction, with `lock_timeout` set inside it. A `checkout` around every
  user inherited DBConnection's 15s and crashed boot at 1,637 users.

  A pre-check skips the walk when no note needs anything, but only on a
  connection that can see every tenant: a superuser or BYPASSRLS role, or one
  that may `SET ROLE engram_maintenance`, whose `maintenance_all` policies
  show it every row. Any other role sees no row without a tenant, so the same
  query would answer "nothing to do" on every database; it walks instead. A
  pre-check that cannot see costs time, never a body.
  """

  require Logger

  @window 1_000
  # One window: 1,000 whole bodies copied at worst, on a self-hoster's disk.
  @window_timeout_ms 120_000

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

  # The same question over every user. Only true to its answer on a
  # connection `@visibility` says can see them all.
  @any_left """
  SELECT EXISTS (
    SELECT 1 FROM notes n
    WHERE n.kind = 'note'
      AND NOT EXISTS (SELECT 1 FROM note_bodies x WHERE x.note_id = n.id AND x.user_id = n.user_id)
  )
  """

  # Whether this connection bypasses RLS, and whether it can become a role
  # that a policy shows every row. CASE, not AND: `pg_has_role` raises on an
  # unknown role and AND does not promise to test the name first.
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

  # True when body column `body` holds the envelope under the `notes` nonce
  # (its 13-byte nonce field; for a pre-nonce row, the copy's first 13
  # bytes): the in-step test of the null batch and the write fences.
  in_step = fn body, ct, nonce ->
    """
    (b.#{body} IS NOT NULL AND substring(b.#{body} FROM 1 FOR 13) = substring((CASE
      WHEN n.#{nonce} IS NULL THEN n.#{ct}
      WHEN length(n.#{nonce}) = 13 THEN n.#{nonce}
      ELSE '\\x00'::bytea || n.#{nonce} END) FROM 1 FOR 13))
    """
  end

  c_ok = in_step.("content_ct", "content_ciphertext", "content_nonce")
  s_ok = in_step.("crdt_ct", "crdt_state_ciphertext", "crdt_state_nonce")
  c_copy = merged.("content_ciphertext", "content_nonce")
  s_copy = merged.("crdt_state_ciphertext", "crdt_state_nonce")

  head =
    "CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$' " <>
      "THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END"

  # The repair, RLS bypassed on `note_bodies`: the row goes back to the
  # note's owner, and existing body bytes are never overwritten (SQL cannot
  # tell a stale `notes` copy, which release B leaves under a newer nonce,
  # from a stale body). Per column: a body value is kept (`body` when it
  # holds the envelope under the `notes` nonce, `mismatch` when it does not,
  # logged for a human look); a NULL body is rebuilt from the `notes` copy
  # when the copy's nonce is set (`copy`), else stays NULL (`none`). The head
  # follows the CRDT state it was computed from.
  path = fn body, ok, nonce, copy ->
    """
    CASE WHEN b.#{body} IS NOT NULL THEN (CASE WHEN #{ok} THEN 'body' ELSE 'mismatch' END)
      WHEN n.#{nonce} IS NOT NULL AND #{copy} IS NOT NULL THEN 'copy' ELSE 'none' END
    """
  end

  value = fn body, nonce, copy ->
    "CASE WHEN b.#{body} IS NOT NULL THEN b.#{body} WHEN n.#{nonce} IS NOT NULL THEN #{copy} END"
  end

  @repair """
  WITH r AS (
    SELECT n.id, n.user_id,
      CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END AS key_version,
      #{path.("content_ct", c_ok, "content_nonce", c_copy)} AS c_path,
      #{path.("crdt_ct", s_ok, "crdt_state_nonce", s_copy)} AS s_path,
      #{value.("content_ct", "content_nonce", c_copy)} AS content_ct,
      #{value.("crdt_ct", "crdt_state_nonce", s_copy)} AS crdt_ct,
      CASE WHEN b.crdt_ct IS NULL AND n.crdt_state_nonce IS NOT NULL AND #{s_copy} IS NOT NULL
        THEN #{head} ELSE b.crdt_head END AS crdt_head
    FROM notes n JOIN note_bodies b ON b.note_id = n.id
    WHERE n.id = ANY($1::uuid[]) AND b.note_id = ANY($1::uuid[]) AND n.user_id = $2
      AND n.kind = 'note' AND b.user_id <> n.user_id
  )
  UPDATE note_bodies b SET
    user_id = r.user_id, key_version = r.key_version,
    content_ct = r.content_ct, crdt_ct = r.crdt_ct, crdt_head = r.crdt_head
  FROM r WHERE b.note_id = r.id
  RETURNING b.note_id::text, r.c_path, r.s_path
  """

  def up, do: complete_split(repo())

  def down, do: :ok

  @doc false
  # The whole migration on `repo`; public for `SelfHostJumpTest`.
  def complete_split(repo) do
    if work_remains?(repo) do
      %{rows: users} = repo.query!("SELECT id FROM users ORDER BY id")
      Enum.each(users, fn [user_id] -> user!(repo, user_id) end)
    end

    :ok
  end

  # True unless a connection that can see every tenant found nothing to do.
  # One anti-join over `notes`, so `timeout: :infinity` on that statement alone.
  defp work_remains?(repo) do
    case repo.query!(@visibility).rows do
      [[true, _]] -> any_left?(repo)
      [[_, true]] -> any_left_as_maintenance?(repo)
      _ -> true
    end
  end

  defp any_left?(repo) do
    %{rows: [[any?]]} = repo.query!(@any_left, [], timeout: :infinity)
    any?
  end

  # The role is cleared before the transaction ends, like the tenant below.
  defp any_left_as_maintenance?(repo) do
    {:ok, any?} =
      repo.transaction(
        fn ->
          repo.query!("SET LOCAL ROLE engram_maintenance")
          any? = any_left?(repo)
          repo.query!("SELECT set_config('role', 'none', true)")
          any?
        end,
        timeout: :infinity
      )

    any?
  end

  defp user!(repo, user_id) do
    walk(repo, user_id, <<0::128>>)
    check(repo, user_id, left(repo, user_id))
  end

  # Repairs until no note of the user reads with no body, or a repair makes
  # no progress (a note with no body row at all: none after the walk).
  defp check(_repo, _user_id, []), do: :ok

  defp check(repo, user_id, ids) do
    repair(repo, user_id, ids)

    case left(repo, user_id) do
      ^ids ->
        # A warning, never a raise: a raising migration blocks every boot.
        Logger.warning("note_bodies split incomplete: notes still read with no body",
          category: :data,
          user_id: Ecto.UUID.load!(user_id),
          note_ids: Enum.map(ids, &Ecto.UUID.load!/1)
        )

      rest ->
        check(repo, user_id, rest)
    end
  end

  defp left(repo, user_id) do
    tenant(repo, user_id, fn -> Enum.map(repo.query!(@left, [user_id]).rows, &hd/1) end)
  end

  # Only for a user with a note under a foreign body row (prod: none).
  defp repair(repo, user_id, ids) do
    rows =
      tenant(repo, user_id, fn ->
        repo.query!("ALTER TABLE note_bodies NO FORCE ROW LEVEL SECURITY")
        %{rows: rows} = repo.query!(@repair, [ids, user_id])
        repo.query!("ALTER TABLE note_bodies FORCE ROW LEVEL SECURITY")
        rows
      end)

    meta = [category: :data, user_id: Ecto.UUID.load!(user_id)]

    rows
    |> Enum.group_by(fn [_id, c, s] -> {c, s} end, &hd/1)
    |> Enum.each(fn {{c, s}, note_ids} ->
      Logger.warning(
        "note_bodies split: body rows handed back to their owner " <>
          "(content: #{c}, CRDT state: #{s}; none = no body)",
        meta ++ [note_ids: note_ids]
      )
    end)

    case for [id, c, s] <- rows, "mismatch" in [c, s], do: id do
      [] ->
        :ok

      odd ->
        Logger.warning(
          "note_bodies split: a body kept as it is does not match its notes nonce, " <>
            "check it by hand (note ids: #{Enum.join(odd, ", ")})",
          meta ++ [note_ids: odd]
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
      repo.transaction(
        fn ->
          repo.query!(
            "SELECT set_config('app.current_tenant', $1::uuid::text, true), " <>
              "set_config('lock_timeout', '5s', true)",
            [user_id]
          )

          result = fun.()
          repo.query!("SELECT set_config('app.current_tenant', '', true)")
          result
        end,
        timeout: @window_timeout_ms
      )

    result
  end
end
