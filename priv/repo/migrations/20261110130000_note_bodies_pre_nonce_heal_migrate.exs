defmodule Engram.Repo.Migrations.NoteBodiesPreNonceHealMigrate do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Heals the notes the R8(c) owner repair (20261107120000) left reading
  empty before its fix (#2545 review MED-1). That repair handed a foreign
  body row back to its note's owner but rebuilt a NULL body column from the
  `notes` copy only when the copy's nonce was set. A pre-nonce note (nonce
  NULL, the envelope merged into the `notes` ciphertext) kept a NULL body,
  read empty, and counted as done; its only bytes are the `notes` column
  R8(e) drops. Databases that recorded 20261107120000 never rerun the fixed
  repair, so this one does the fill.

  Per column: a NULL body column over a `notes` ciphertext with a NULL
  nonce takes the ciphertext as it is, exactly what the walk's insert
  writes for that row. Nothing else is touched: a set body is never
  overwritten, and a NULL body over a copy with a nonce is not this bug
  (the old repair copied those). The head follows the CRDT state it was
  computed from, as in the repair.

  The body row is the owner's now, so the tenant policy reaches it: no RLS
  bypass and no table lock. One tenanted `EXISTS` per user (#{200} users
  per short transaction) picks out the users with such a note; only those
  are walked, in id windows of #{100} notes, one transaction each, under a
  5s `lock_timeout` and a `statement_timeout` inside the checkout deadline.
  A probe batch still locked out after two retries, or past its timeout, is
  walked anyway. A window past its timeout (Postgres 57014 or the checkout
  deadline; a dropped connection is raised) is halved at most #{4} times;
  past that its notes are logged and stepped over. One run has a #{90} s
  deadline: nothing starts past it and every `statement_timeout` ends at
  it. Notes stepped over, users not reached, or a window still locked out
  after two retries: the run raises with the counts, not recorded, and the
  next boot resumes where this one stopped. Recording would leave those
  notes empty for good once R8(e) drops their only bytes (the hotfix's
  raise, same reason).

  Prod (2026-11-10): no body row was ever under another owner, so no note
  is in this state; it runs the probe only (2 statements a user, ~1,637
  users). Rerun-safe; no `down` work. Calls no app module: the N-1 gate
  runs it on the previous release's code, so the probe and window helpers
  are copied from 20261107120000, not shared.
  """

  require Logger

  @window 100
  # At most per statement; never past the run's deadline.
  @statement_timeout_ms 110_000
  @lock_timeout "5s"
  # One run stops starting work this long after it began, then raises.
  @deadline_ms 90_000
  # A window past its timeout is halved at most this often (100 -> 6).
  @max_halvings 4
  @retries 2
  @probe_batch 200
  @contention [:lock_not_available, :deadlock_detected]

  broken = fn body, ct, nonce ->
    "(b.#{body} IS NULL AND n.#{nonce} IS NULL AND n.#{ct} IS NOT NULL)"
  end

  c_broken = broken.("content_ct", "content_ciphertext", "content_nonce")
  s_broken = broken.("crdt_ct", "crdt_state_ciphertext", "crdt_state_nonce")

  from = """
  FROM notes n JOIN note_bodies b ON b.note_id = n.id AND b.user_id = n.user_id
  WHERE n.user_id = $1 AND n.kind = 'note' AND (#{c_broken} OR #{s_broken})
  """

  @probe "SELECT EXISTS (SELECT 1 #{from})"

  @heal """
  WITH w AS (
    SELECT n.id #{from} AND n.id > $2 ORDER BY n.id LIMIT $3
  ), up AS (
    UPDATE note_bodies b SET
      content_ct = CASE WHEN #{c_broken} THEN n.content_ciphertext ELSE b.content_ct END,
      crdt_ct = CASE WHEN #{s_broken} THEN n.crdt_state_ciphertext ELSE b.crdt_ct END,
      crdt_head = CASE WHEN #{s_broken}
        THEN (CASE WHEN n.crdt_head ~ '^[A-Za-z0-9_-]{43}$'
          THEN decode(translate(n.crdt_head, '-_', '+/') || '=', 'base64') END)
        ELSE b.crdt_head END
    FROM notes n JOIN w ON w.id = n.id
    WHERE b.note_id = n.id AND b.user_id = n.user_id
    RETURNING b.note_id
  )
  SELECT (SELECT id FROM w ORDER BY id DESC LIMIT 1), (SELECT count(*) FROM up)::int
  """

  @window_rows "SELECT n.id #{from} AND n.id > $2 ORDER BY n.id LIMIT $3"

  def up, do: heal(repo())

  def down, do: :ok

  @doc false
  # Public for `NoteBodiesPreNonceHealTest`, which also passes
  # `:deadline_ms` and `:max_halvings`.
  def heal(repo, opts \\ []) do
    started = now()

    ctx = %{
      deadline: started + Keyword.get(opts, :deadline_ms, @deadline_ms),
      max_halvings: Keyword.get(opts, :max_halvings, @max_halvings)
    }

    %{rows: users} = repo.query!("SELECT id FROM users ORDER BY id")

    needing =
      users
      |> Enum.map(&hd/1)
      |> Enum.chunk_every(@probe_batch)
      |> Enum.flat_map(&probe(repo, &1, ctx, @retries))

    {slow, late, healed} =
      Enum.reduce(needing, {0, 0, 0}, fn user_id, {slow, late, healed} ->
        case walk(repo, user_id, <<0::128>>, {@window, 0}, {0, 0}, ctx) do
          {:done, {more, n}} -> {slow + more, late, healed + n}
          {:cut, {more, n}} -> {slow + more, late + 1, healed + n}
        end
      end)

    # Counts and timing only, never an id. `:boot` info lines ship to Loki
    # (`Engram.Logger.Category`, spelled out as a migration calls no app
    # module). Prod's post-release check reads it: staging never ran a heal.
    Logger.info(
      "note_bodies pre-nonce heal: #{length(users)} user(s) probed, " <>
        "#{length(needing)} with work, #{healed} note(s) healed " <>
        "(#{now() - started} ms)",
      category: :boot,
      loki_ship: true
    )

    if slow + late > 0 do
      gaps =
        Enum.reject(
          [
            slow > 0 && "#{slow} note(s) too slow to heal at the smallest window",
            late > 0 && "#{late} user(s) not finished before the boot deadline"
          ],
          &(&1 == false)
        )

      raise "note_bodies pre-nonce heal: #{Enum.join(gaps, ", ")}; " <>
              "not recording this migration, the next boot resumes"
    end

    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Copied from 20261107120000, not in lib/: the N-1 gate runs this on the old release.
  defp budget(ctx) do
    case ctx.deadline - now() do
      left when left > 0 -> min(left, @statement_timeout_ms)
      _ -> :expired
    end
  end

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

          needing =
            Enum.filter(batch, fn user_id ->
              repo.query!("SELECT set_config('app.current_tenant', $1::uuid::text, true)", [
                user_id
              ])

              repo.query!(@probe, [user_id]).rows == [[true]]
            end)

          repo.query!("SELECT set_config('app.current_tenant', '', true)")
          needing
        end,
        timeout: ms + 10_000
      )

    needing
  end

  # `{:done | :cut, {slow, healed}}`: `:cut` once the deadline passed,
  # `slow` the count of notes stepped over at the smallest window, `healed`
  # the count of body rows written.
  defp walk(repo, user_id, after_id, {size, halvings}, {slow, healed} = acc, ctx) do
    case window(repo, user_id, after_id, size, ctx) do
      :expired ->
        {:cut, acc}

      [[nil, _]] ->
        {:done, acc}

      [[last, n]] ->
        walk(repo, user_id, last, {size, halvings}, {slow, healed + n}, ctx)

      :too_slow ->
        cond do
          budget(ctx) == :expired ->
            {:cut, acc}

          halvings < ctx.max_halvings and size > 1 ->
            walk(repo, user_id, after_id, {div(size, 2), halvings + 1}, acc, ctx)

          true ->
            tenant(repo, user_id, fn ->
              Enum.map(repo.query!(@window_rows, [user_id, after_id, size]).rows, &hd/1)
            end)
            |> step_over(repo, user_id, acc, ctx)
        end
    end
  end

  defp step_over([], _repo, _user_id, acc, _ctx), do: {:done, acc}

  defp step_over(ids, repo, user_id, {slow, healed}, ctx) do
    note_ids = Enum.map(ids, &Ecto.UUID.load!/1)

    Logger.warning(
      "note_bodies pre-nonce heal: #{length(ids)} note(s) too slow to heal at the " <>
        "smallest window (note ids: #{Enum.join(note_ids, ", ")})",
      category: :data,
      user_id: Ecto.UUID.load!(user_id),
      note_ids: note_ids
    )

    walk(repo, user_id, List.last(ids), {@window, 0}, {slow + length(ids), healed}, ctx)
  end

  defp window(repo, user_id, after_id, size, ctx) do
    case budget(ctx) do
      :expired ->
        :expired

      ms ->
        tenant(repo, user_id, fn -> repo.query!(@heal, [user_id, after_id, size]).rows end, ms)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      if timeout?(e), do: :too_slow, else: reraise(e, __STACKTRACE__)
  end

  # Only a deadline is a slow run: Postgres 57014 (`statement_timeout`) or
  # DBConnection's checkout deadline. A dropped connection is raised.
  defp timeout?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true
  defp timeout?(%DBConnection.ConnectionError{message: message}), do: message =~ "timed out"
  defp timeout?(_error), do: false

  defp contention?(%Postgrex.Error{postgres: %{code: code}}), do: code in @contention
  defp contention?(_error), do: false

  defp tenant(repo, user_id, fun, ms \\ @statement_timeout_ms, retries \\ @retries) do
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
  rescue
    e in Postgrex.Error ->
      if retries > 0 and contention?(e),
        do: tenant(repo, user_id, fun, ms, retries - 1),
        else: reraise(e, __STACKTRACE__)
  end
end
