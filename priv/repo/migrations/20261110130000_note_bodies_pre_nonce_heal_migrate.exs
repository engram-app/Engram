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
  A probe batch still locked out after two retries is walked anyway. A
  window that hits the deadline is halved down to one note; a note too slow
  even alone is logged and stepped over, and the run raises at the end with
  the count, as does a window still locked out after two retries: not
  recorded, the next boot resumes. Recording would leave that note empty
  for good once R8(e) drops its only bytes (the hotfix's raise, same
  reason).

  Prod (2026-11-10): no body row was ever under another owner, so no note
  is in this state; it runs the probe only (2 statements a user, ~1,637
  users). Rerun-safe; no `down` work. Calls no app module: the N-1 gate
  runs it on the previous release's code, so the probe and window helpers
  are copied from 20261107120000, not shared.
  """

  require Logger

  @window 100
  @window_timeout_ms 120_000
  @statement_timeout "110s"
  @lock_timeout "5s"
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

  @next "SELECT n.id #{from} AND n.id > $2 ORDER BY n.id LIMIT 1"

  def up, do: heal(repo())

  def down, do: :ok

  @doc false
  # Public for `NoteBodiesPreNonceHealTest`.
  def heal(repo) do
    %{rows: users} = repo.query!("SELECT id FROM users ORDER BY id")

    users
    |> Enum.map(&hd/1)
    |> Enum.chunk_every(@probe_batch)
    |> Enum.flat_map(&probe(repo, &1, @retries))
    |> Enum.reduce(0, &(&2 + walk(repo, &1, <<0::128>>, @window, 0)))
    |> case do
      0 ->
        :ok

      slow ->
        raise "note_bodies pre-nonce heal: #{slow} note(s) too slow to heal even alone; " <>
                "not recording this migration, the next boot resumes"
    end
  end

  # Copied from 20261107120000, not in lib/: the N-1 gate runs this on the old release.
  defp probe(repo, batch, retries) do
    {:ok, needing} =
      repo.transaction(
        fn ->
          repo.query!("SELECT set_config('lock_timeout', '#{@lock_timeout}', true)")

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
        timeout: @window_timeout_ms
      )

    needing
  rescue
    e in Postgrex.Error ->
      cond do
        not contention?(e) -> reraise(e, __STACKTRACE__)
        retries > 0 -> probe(repo, batch, retries - 1)
        true -> batch
      end
  end

  # Returns the count of notes too slow to heal even alone.
  defp walk(repo, user_id, after_id, size, slow) do
    case window(repo, user_id, after_id, size) do
      [[nil, _]] ->
        slow

      [[last, _]] ->
        walk(repo, user_id, last, size, slow)

      :too_slow when size > 1 ->
        walk(repo, user_id, after_id, div(size, 2), slow)

      :too_slow ->
        case tenant(repo, user_id, fn -> repo.query!(@next, [user_id, after_id]).rows end) do
          [] ->
            slow

          [[id]] ->
            Logger.warning(
              "note_bodies pre-nonce heal: a note too slow to heal even alone (note id: #{Ecto.UUID.load!(id)})",
              category: :data,
              user_id: Ecto.UUID.load!(user_id),
              note_ids: [Ecto.UUID.load!(id)]
            )

            walk(repo, user_id, id, @window, slow + 1)
        end
    end
  end

  # A window past its deadline: the server cancels it (`statement_timeout`)
  # or DBConnection drops the connection; either way nothing committed.
  defp window(repo, user_id, after_id, size) do
    tenant(repo, user_id, fn -> repo.query!(@heal, [user_id, after_id, size]).rows end)
  rescue
    DBConnection.ConnectionError -> :too_slow
    e in Postgrex.Error -> if canceled?(e), do: :too_slow, else: reraise(e, __STACKTRACE__)
  end

  defp canceled?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true
  defp canceled?(_error), do: false

  defp contention?(%Postgrex.Error{postgres: %{code: code}}), do: code in @contention
  defp contention?(_error), do: false

  defp tenant(repo, user_id, fun, retries \\ @retries) do
    {:ok, result} =
      repo.transaction(
        fn ->
          repo.query!(
            "SELECT set_config('app.current_tenant', $1::uuid::text, true), " <>
              "set_config('lock_timeout', '#{@lock_timeout}', true), " <>
              "set_config('statement_timeout', '#{@statement_timeout}', true)",
            [user_id]
          )

          result = fun.()
          repo.query!("SELECT set_config('app.current_tenant', '', true)")
          result
        end,
        timeout: @window_timeout_ms
      )

    result
  rescue
    e in Postgrex.Error ->
      if retries > 0 and contention?(e),
        do: tenant(repo, user_id, fun, retries - 1),
        else: reraise(e, __STACKTRACE__)
  end
end
