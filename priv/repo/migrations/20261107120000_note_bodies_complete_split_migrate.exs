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
  NULL body column is rebuilt from the `notes` copy, in the merged layout
  the walk's insert writes (a pre-nonce copy, nonce NULL, as it is). A note's envelopes are bound to its own id (AAD) and its owner's
  key, so bytes written for it decrypt once the row is the owner's again.
  Each path is logged with the note ids; the repair repeats until the user
  has no such note, and a note still unreadable after that logs a warning.
  Never a raise for that: a raising migration blocks every boot (zero
  operator action), and no retry would change the answer.

  One raise is lock contention, which a later boot can get past. A
  window that hits a lock timeout or deadlock is retried twice. A user that
  still fails is skipped: the migration continues through the other users,
  retries the skipped users in a final pass, and raises at the end with the
  count, so it is not recorded and the next boot resumes. Finishing instead
  would record it, it would never run again, and that user's notes would be
  left with no body once readers stop falling back to the `notes` columns.
  The cost is a failed boot while the contention lasts. Locks are only taken
  where rows need writing, so a database with nothing to split cannot reach
  this.

  Prod (2026-11-07): 0 notes without a body row and 0 body rows under
  another owner, so it inserts nothing and takes no table lock. Rerun-safe;
  no `down` work (the rows are what every release from 0.76 on writes).
  Calls no app module.

  No connection is held across the walk: each window is its own short
  transaction, with `lock_timeout` set inside it. A `checkout` around every
  user inherited DBConnection's 15s and crashed boot at 1,637 users.

  One run has a #{90} s deadline (ECS replaces a task not healthy ~150 s
  after start): no window, repair or probe batch starts past it, and each
  one's `statement_timeout` (at most 110 s) ends at it, so a run stops
  within a few seconds of it. A window or repair batch (#{50} owner
  repairs at most, each holding ACCESS EXCLUSIVE on `note_bodies`) past its
  timeout is halved, at most #{4} times (1,000 -> 62); past that its notes
  are logged and stepped over. Only a timeout counts (Postgres 57014 or
  DBConnection's checkout deadline): a dropped connection is raised. A run
  that stepped over notes or hit the deadline raises with the counts once
  every user it reached is done: recording it would leave those notes with
  no body for good once readers stop falling back (the same reason as the
  contention raise above). Windows commit as they go, so each boot resumes
  where the last stopped.

  Before any walk, one tenanted `EXISTS` per user (in batches of #{200} users
  per short transaction, under the same `lock_timeout` and
  `statement_timeout`) picks out the users with a note that reads with no
  body, a body row under another owner included; only those are walked. A
  batch still locked out after two retries, or past its timeout, is walked
  whole.

  A pre-check skips all of that when no note needs anything, but only on a
  connection that can see every tenant: a superuser or BYPASSRLS role, or one
  that may `SET ROLE engram_maintenance`, whose `maintenance_all` policies
  show it every row. Any other role sees no row without a tenant, so the same
  query would answer "nothing to do" on every database; it goes per user
  instead. A pre-check that cannot see costs time, never a body.
  """

  require Logger

  # One window: 1,000 whole bodies copied at worst, on a self-hoster's disk.
  @window 1_000
  # Cancels a window's statement server-side inside the checkout deadline,
  # and never past the run's deadline.
  @statement_timeout_ms 110_000
  @lock_timeout "5s"
  # One run stops starting work this long after it began (ECS replaces a
  # task that is not healthy ~150 s after start), and raises with the count.
  @deadline_ms 90_000
  # A window or repair batch past its deadline is halved at most this often
  # (1,000 -> 62); past that its notes count as unfinished.
  @max_halvings 4
  # Owner repairs per transaction: each holds ACCESS EXCLUSIVE on note_bodies.
  @repair_batch 50
  @window_retries 2
  @probe_batch 200
  @progress_every 250
  @contention [:lock_not_available, :deadlock_detected]

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
    SELECT id FROM notes WHERE user_id = $1 AND id > $2 ORDER BY id LIMIT $3
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

  # The rows of a window, to step over one that cannot finish.
  @window_rows "SELECT id, kind = 'note' FROM notes WHERE user_id = $1 AND id > $2 ORDER BY id LIMIT $3"

  # Notes of the user that read with no body: no body row of the same
  # owner (`NoteBody.join/1` matches the owner too). The same answer with or
  # without RLS bypass.
  @left """
  SELECT n.id FROM notes n
  WHERE n.user_id = $1 AND n.kind = 'note'
    AND NOT EXISTS (SELECT 1 FROM note_bodies x WHERE x.note_id = n.id AND x.user_id = n.user_id)
  ORDER BY n.id LIMIT #{@window}
  """

  # The same question for one user, in that user's tenant context. A body row
  # under another owner is hidden by the policy, so it reads as missing.
  @user_left """
  SELECT EXISTS (
    SELECT 1 FROM notes n
    WHERE n.user_id = $1 AND n.kind = 'note'
      AND NOT EXISTS (SELECT 1 FROM note_bodies x WHERE x.note_id = n.id AND x.user_id = n.user_id)
  )
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
  # (`copy`, the insert's `merged` layout, so a pre-nonce copy too), else
  # stays NULL (`none`). The head follows the CRDT state it was computed from.
  path = fn body, ok, copy ->
    """
    CASE WHEN b.#{body} IS NOT NULL THEN (CASE WHEN #{ok} THEN 'body' ELSE 'mismatch' END)
      WHEN #{copy} IS NOT NULL THEN 'copy' ELSE 'none' END
    """
  end

  value = fn body, copy -> "COALESCE(b.#{body}, #{copy})" end

  @repair """
  WITH r AS (
    SELECT n.id, n.user_id,
      CASE WHEN n.dek_version BETWEEN 0 AND 32767 THEN n.dek_version ELSE 0 END AS key_version,
      #{path.("content_ct", c_ok, c_copy)} AS c_path,
      #{path.("crdt_ct", s_ok, s_copy)} AS s_path,
      #{value.("content_ct", c_copy)} AS content_ct,
      #{value.("crdt_ct", s_copy)} AS crdt_ct,
      CASE WHEN b.crdt_ct IS NULL AND #{s_copy} IS NOT NULL
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
  # The whole migration on `repo`; public for `SelfHostJumpTest`, which also
  # passes `:deadline_ms` and `:max_halvings`.
  def complete_split(repo, opts \\ []) do
    if work_remains?(repo) do
      ctx = %{
        deadline: now() + Keyword.get(opts, :deadline_ms, @deadline_ms),
        max_halvings: Keyword.get(opts, :max_halvings, @max_halvings)
      }

      %{rows: users} = repo.query!("SELECT id FROM users ORDER BY id")
      split_users(repo, Enum.map(users, &hd/1), ctx)
    end

    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Milliseconds left in the run, at most one statement's worth; `:expired`
  # once it is spent.
  defp budget(ctx) do
    case ctx.deadline - now() do
      left when left > 0 -> min(left, @statement_timeout_ms)
      _ -> :expired
    end
  end

  defp split_users(repo, users, ctx) do
    started = now()
    pending = users_needing_work(repo, users, ctx)
    boot_log("walk started: #{length(pending)} of #{length(users)} users need work", started)

    first = walk_users(pending, repo, started, ctx)
    final = walk_users(first.skipped, repo, started, ctx)
    slow = first.slow + final.slow
    late = first.late + final.late

    if final.skipped == [] and slow == 0 and late == 0 do
      boot_log("walk finished: #{length(pending)} users", started)
    else
      gaps =
        Enum.reject(
          [
            final.skipped != [] &&
              "#{length(final.skipped)} user(s) still need work after retries (lock contention)",
            slow > 0 && "#{slow} note(s) too slow to copy at the smallest window",
            late > 0 && "#{late} user(s) not finished before the boot deadline"
          ],
          &(&1 == false)
        )

      raise "note_bodies split: #{Enum.join(gaps, ", ")}; " <>
              "not recording this migration, the next boot resumes"
    end
  end

  defp users_needing_work(repo, users, ctx) do
    users
    |> Enum.chunk_every(@probe_batch)
    |> Enum.flat_map(&probe(repo, &1, ctx, @window_retries))
  end

  # Under the windows' `lock_timeout` and `statement_timeout`, so a queued
  # DDL lock or a slow plan fails the batch fast instead of at the checkout
  # deadline. Contention is retried; a batch still locked out, past its
  # timeout, or reached after the deadline is walked whole (the walk has its
  # own retries and deadline).
  defp probe(repo, batch, ctx, retries) do
    case budget(ctx) do
      :expired -> batch
      ms -> probe_batch(repo, batch, ms)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      cond do
        retries > 0 and contention?(e) -> probe(repo, batch, ctx, retries - 1)
        contention?(e) or timeout?(e) -> batch
        true -> reraise(e, __STACKTRACE__)
      end
  end

  defp probe_batch(repo, batch, ms) do
    {:ok, needing} =
      repo.transaction(
        fn ->
          repo.query!(
            "SELECT set_config('lock_timeout', '#{@lock_timeout}', true), " <>
              "set_config('statement_timeout', '#{ms}ms', true)"
          )

          needing = Enum.filter(batch, &user_left?(repo, &1))
          repo.query!("SELECT set_config('app.current_tenant', '', true)")
          needing
        end,
        timeout: ms + 10_000
      )

    needing
  end

  defp user_left?(repo, user_id) do
    repo.query!("SELECT set_config('app.current_tenant', $1::uuid::text, true)", [user_id])
    %{rows: [[left?]]} = repo.query!(@user_left, [user_id])
    left?
  end

  # The users skipped for lock contention, the count of notes too slow at
  # the smallest window, and the count of users not finished by the deadline.
  defp walk_users(users, repo, started, ctx) do
    total = length(users)

    acc =
      users
      |> Enum.with_index(1)
      |> Enum.reduce(%{skipped: [], slow: 0, late: 0}, fn {user_id, done}, acc ->
        result = if budget(ctx) == :expired, do: {:cut, []}, else: split_user(repo, user_id, ctx)

        if rem(done, @progress_every) == 0 do
          boot_log("walk progress: #{done} of #{total} users", started)
        end

        case result do
          :contention -> %{acc | skipped: [user_id | acc.skipped]}
          {:done, slow} -> %{acc | slow: acc.slow + length(slow)}
          {:cut, slow} -> %{acc | slow: acc.slow + length(slow), late: acc.late + 1}
        end
      end)

    %{acc | skipped: Enum.reverse(acc.skipped)}
  end

  defp split_user(repo, user_id, ctx) do
    user!(repo, user_id, ctx)
  rescue
    e in Postgrex.Error ->
      if contention?(e), do: :contention, else: reraise(e, __STACKTRACE__)
  end

  defp contention?(%Postgrex.Error{postgres: %{code: code}}), do: code in @contention
  defp contention?(_error), do: false

  # Counts and timing only, never a user id. `:boot` info lines ship to Loki
  # (`Engram.Logger.Category`, spelled out as a migration calls no app module).
  defp boot_log(message, started) do
    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("note_bodies split #{message} (#{elapsed} ms)", category: :boot, loki_ship: true)
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

  # `{:done | :cut, slow}`: `:cut` once the deadline passed, `slow` the ids
  # of the notes too slow at the smallest window.
  defp user!(repo, user_id, ctx) do
    case walk(repo, user_id, <<0::128>>, {@window, 0}, [], ctx) do
      {:done, slow} -> check(repo, user_id, left(repo, user_id) -- slow, slow, ctx)
      cut -> cut
    end
  end

  # Repairs until no note of the user reads with no body, or a repair makes
  # no progress (a note with no body row at all: none after the walk).
  # Notes too slow at the smallest batch are left out, and returned.
  defp check(_repo, _user_id, [], slow, _ctx), do: {:done, slow}

  defp check(repo, user_id, ids, slow, ctx) do
    case repair_all(repo, user_id, ids, ctx) do
      {:cut, more} ->
        {:cut, more ++ slow}

      {:done, more} ->
        slow = more ++ slow

        case left(repo, user_id) -- slow do
          ^ids ->
            # A warning, never a raise: no retry would change the answer.
            Logger.warning("note_bodies split incomplete: notes still read with no body",
              category: :data,
              user_id: Ecto.UUID.load!(user_id),
              note_ids: Enum.map(ids, &Ecto.UUID.load!/1)
            )

            {:done, slow}

          rest ->
            check(repo, user_id, rest, slow, ctx)
        end
    end
  end

  defp left(repo, user_id) do
    tenant(repo, user_id, fn -> Enum.map(repo.query!(@left, [user_id]).rows, &hd/1) end)
  end

  defp repair_all(repo, user_id, ids, ctx) do
    ids
    |> Enum.chunk_every(@repair_batch)
    |> Enum.reduce_while({:done, []}, fn batch, {:done, slow} ->
      case repair(repo, user_id, batch, 0, ctx) do
        {:done, more} -> {:cont, {:done, more ++ slow}}
        {:cut, more} -> {:halt, {:cut, more ++ slow}}
      end
    end)
  end

  # Only for a user with a note under a foreign body row (prod: none). A
  # batch past its deadline is halved up to `max_halvings` times; past that
  # its ids are returned as too slow.
  defp repair(repo, user_id, ids, halvings, ctx) do
    fun = fn ->
      repo.query!("ALTER TABLE note_bodies NO FORCE ROW LEVEL SECURITY")
      %{rows: rows} = repo.query!(@repair, [ids, user_id])
      repo.query!("ALTER TABLE note_bodies FORCE ROW LEVEL SECURITY")
      rows
    end

    case attempt(repo, user_id, fun, ctx) do
      :expired ->
        {:cut, []}

      :too_slow ->
        cond do
          budget(ctx) == :expired ->
            {:cut, []}

          halvings < ctx.max_halvings and length(ids) > 1 ->
            {first, second} = Enum.split(ids, div(length(ids), 2))

            case repair(repo, user_id, first, halvings + 1, ctx) do
              {:done, slow} ->
                {status, more} = repair(repo, user_id, second, halvings + 1, ctx)
                {status, slow ++ more}

              cut ->
                cut
            end

          true ->
            too_slow(user_id, ids, "repair")
            {:done, ids}
        end

      rows ->
        log_repair(user_id, rows)
        {:done, []}
    end
  end

  defp log_repair(user_id, rows) do
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

  # A window past its deadline is halved up to `max_halvings` times. Past
  # that its notes are logged and stepped over; their ids are returned, and
  # the run raises at the end with the count, so it is not recorded.
  defp walk(repo, user_id, after_id, {size, halvings}, slow, ctx) do
    insert = fn -> repo.query!(@insert, [user_id, after_id, size]).rows end

    case attempt(repo, user_id, insert, ctx) do
      :expired ->
        {:cut, slow}

      [[nil, _]] ->
        {:done, slow}

      [[last, _]] ->
        walk(repo, user_id, last, {size, halvings}, slow, ctx)

      :too_slow ->
        cond do
          budget(ctx) == :expired ->
            {:cut, slow}

          halvings < ctx.max_halvings and size > 1 ->
            walk(repo, user_id, after_id, {div(size, 2), halvings + 1}, slow, ctx)

          true ->
            tenant(repo, user_id, fn ->
              repo.query!(@window_rows, [user_id, after_id, size]).rows
            end)
            |> step_over(repo, user_id, slow, ctx)
        end
    end
  end

  defp step_over([], _repo, _user_id, slow, _ctx), do: {:done, slow}

  defp step_over(rows, repo, user_id, slow, ctx) do
    ids = for [id, true] <- rows, do: id
    too_slow(user_id, ids, "copy")
    walk(repo, user_id, rows |> List.last() |> hd(), {@window, 0}, ids ++ slow, ctx)
  end

  defp too_slow(_user_id, [], _step), do: :ok

  defp too_slow(user_id, ids, step) do
    note_ids = Enum.map(ids, &Ecto.UUID.load!/1)

    Logger.warning(
      "note_bodies split: #{length(ids)} note(s) too slow to #{step} at the smallest window " <>
        "(note ids: #{Enum.join(note_ids, ", ")})",
      category: :data,
      user_id: Ecto.UUID.load!(user_id),
      note_ids: note_ids
    )
  end

  # `tenant/4` within the run's budget, a run past its deadline answered
  # `:too_slow` and a spent budget `:expired`. The walk and the repair both
  # go through it.
  defp attempt(repo, user_id, fun, ctx) do
    case budget(ctx) do
      :expired -> :expired
      ms -> tenant(repo, user_id, fun, ms)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      if timeout?(e), do: :too_slow, else: reraise(e, __STACKTRACE__)
  end

  # Only a deadline is a slow run: Postgres cancelling the statement at its
  # `statement_timeout` (57014), or DBConnection's checkout deadline. A
  # dropped connection or a failover is raised, not halved.
  defp timeout?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true
  defp timeout?(%DBConnection.ConnectionError{message: message}), do: message =~ "timed out"
  defp timeout?(_error), do: false

  # One transaction in `user_id`'s RLS context; the tenant is cleared before
  # it ends (a test runs this in a sandbox, where it would outlive a
  # savepoint).
  defp tenant(repo, user_id, fun, ms \\ @statement_timeout_ms, retries \\ @window_retries) do
    in_tenant(repo, user_id, fun, ms)
  rescue
    e in Postgrex.Error ->
      if retries > 0 and contention?(e),
        do: tenant(repo, user_id, fun, ms, retries - 1),
        else: reraise(e, __STACKTRACE__)
  end

  defp in_tenant(repo, user_id, fun, ms) do
    {:ok, result} =
      repo.transaction(
        fn ->
          repo.query!(
            "SELECT set_config('app.current_tenant', $1::uuid::text, true), " <>
              "set_config('lock_timeout', '#{@lock_timeout}', true), " <>
              "set_config('statement_timeout', '#{ms}ms', true)",
            [user_id]
          )

          result = fun.()
          repo.query!("SELECT set_config('app.current_tenant', '', true)")
          result
        end,
        timeout: ms + 10_000
      )

    result
  end
end
