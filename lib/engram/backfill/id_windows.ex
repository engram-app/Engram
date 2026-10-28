defmodule Engram.Backfill.IdWindows do
  @moduledoc """
  The one walk every background sweep, backfill and data migration uses to
  find work: fixed id windows over a table, the predicate applied only inside
  each window. Bounds rows READ per statement, not rows RETURNED (#2276).

  ## Why windows, not "the next N matching rows"

  `WHERE <rare predicate> AND id > $after ORDER BY id LIMIT N` asks Postgres
  for N MATCHES. When matches are rare (the steady state of any backfill that
  works) it walks most of the table to fill the LIMIT, in one statement, and
  the statement grows with the table and with how DONE the job is. A
  fleet-wide `SELECT EXISTS(<rare predicate>)` "anything left?" check is the
  same scan with nothing to stop it early. Both hit DBConnection's 15 s
  per-query timeout in prod (`note_index_state`, 2026-10-28,
  `ERROR 57014 query_canceled`).

  A window is the next N keys by keyset alone (`id > $after ORDER BY id LIMIT
  N`, a primary-key range read), and the caller's predicate runs only against
  those N ids. Each statement reads at most N rows at any table size, and a
  walk over every window that found nothing IS the "nothing left" answer: no
  separate EXISTS scan.

  ## Two scopes

    * `{:fleet, repo}`: every tenant in one walk, on the maintenance pool
      (`Engram.Repo.maintenance/0`), whose `maintenance_all` policies see
      every row. SaaS.
    * `{:user, user_id}`: one tenant, inside that user's RLS context.
      Self-host, and the per-user crypto sweeps.

  `reduce_all/4` picks for the caller: one fleet walk when a maintenance pool
  is configured, else one walk per user (`TenantScan.user_ids/0`).

  Per-user windows filter on `user_id`, and `notes` has no `(user_id, id)`
  index: a per-user window read is bounded by that user's row count, not by
  the window. ponytail: add `notes (user_id, id)` if a single user's rows
  outgrow the 15 s guard; the fleet walk (SaaS) does not need it.

  ## RLS (#1349)

  Every tenant table swept here carries FORCE ROW LEVEL SECURITY, so a
  per-user window read and the step that follows both need
  `app.current_tenant` set. `skip_tenant_check` only silences Engram's own
  `prepare_query/3` guard; it sets nothing in Postgres and does not scope the
  query. Without the `with_tenant` wrapper the window matches zero rows for
  every user, the empty window reads as "nothing left to sweep", and a DEK
  rotation reports success having re-encrypted nothing while its
  `final_flip/3` still lands (`users` has no RLS). Unrecoverable once the old
  key is retired.

  Wrapped per window rather than per walk: a transaction opens per window
  (`with_tenant/2` per user, `repo.transaction/1` on the fleet), and one
  transaction spanning a table would hold every row lock for the duration.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias Engram.Backfill.TenantScan
  alias Engram.Repo

  require Logger

  @batch_size 200
  # Window for the discovery helpers (`all/2`): one primary-key range of
  # 1,000 rows per statement.
  @fleet_window 1_000
  @first_id "00000000-0000-0000-0000-000000000000"

  @type scope :: {:user, Ecto.UUID.t()} | {:fleet, module()}
  @type ctx :: %{repo: module(), user_id: Ecto.UUID.t() | nil}
  @type step_result :: {:cont, term()} | {:halt, term()} | {:error, term()}
  @type result :: {:ok, term()} | {:error, term()}
  # Where a walk resumes: the user (nil on the fleet walk) and the last key
  # of the last window it finished.
  @type cursor :: {Ecto.UUID.t() | nil, Ecto.UUID.t()} | nil

  # The next `size` keys of `schema` after `after_id` (ascending), for one
  # user or (`user_id` nil) the whole table. Caller provides the tenant
  # context.
  defp window(repo, user_id, schema, after_id, size) do
    key = key(schema)

    from(r in schema,
      where: field(r, ^key) > ^after_id,
      order_by: field(r, ^key),
      limit: ^size,
      select: field(r, ^key)
    )
    |> narrow(schema)
    |> then(fn q -> if user_id, do: where(q, [r], r.user_id == ^user_id), else: q end)
    |> repo.all(skip_tenant_check: true)
  end

  # The key column: `id`, except tables keyed otherwise.
  defp key(Engram.Notes.VaultIndexState), do: :vault_id
  defp key(Engram.Notes.ChunkPoint), do: :point_id
  defp key(_schema), do: :id

  # Chunk points are swept only for their display envelope (DEK rotation),
  # so only rows that hold one are visited: notes over the display
  # threshold, none with the chunk-text write flag off. On the partial index
  # `chunk_points_with_display_index` (WHERE display_ct IS NOT NULL).
  defp narrow(q, Engram.Notes.ChunkPoint), do: where(q, [p], not is_nil(p.display_ct))
  defp narrow(q, _schema), do: q

  @doc """
  Folds `fun.(ids, ctx, acc)` over every window of `scope`. `fun` returns
  `{:cont, acc}`, `{:halt, acc}` (stop; the window commits) or
  `{:error, reason}` (stop). Returns `{:ok, acc}` after the last window or a
  halt, or the error.

  `{:fleet, repo}` must be the maintenance pool: `Engram.Repo` raises, since
  FORCE RLS would filter every window to zero rows and the walk would report
  "nothing left" (#1349). Use `reduce_all/4`, which picks the scope.

  Options: `:after` resumes after that key, `:batch_size` is the window
  (default 200), `:fun_in_tenant` (default `true`). With `false`, only the
  window read runs in the scope's context (per user: its tenant
  transaction; fleet: no transaction at all) and `fun` runs outside it,
  owning its own transactions: a caller that commits in smaller pieces than a
  window (the re-encoder, byte-bounded), or one whose writes must commit
  before a side effect (a stamp before its enqueue), needs that.
  """
  @spec reduce(scope(), module(), term(), (list(), ctx(), term() -> step_result()), keyword()) ::
          result()
  def reduce(scope, schema, acc, fun, opts \\ []),
    do: settle(walk_scope(scope, schema, acc, fun, opts))

  # `{:halted, acc}` stays internal: it stops `reduce_all/4`'s user loop.
  defp settle({:halted, acc}), do: {:ok, acc}
  defp settle(result), do: result

  defp walk_scope({:fleet, Repo}, _schema, _acc, _fun, _opts) do
    raise ArgumentError,
          "a fleet-wide id-window walk on Engram.Repo reads zero rows under FORCE RLS " <>
            "(#1349); use the maintenance pool or reduce_all/4"
  end

  defp walk_scope(scope, schema, acc, fun, opts) do
    walk(
      scope,
      schema,
      Keyword.get(opts, :after) || @first_id,
      acc,
      fun,
      Keyword.get(opts, :batch_size, @batch_size),
      Keyword.get(opts, :fun_in_tenant, true)
    )
  end

  defp walk(scope, schema, after_id, acc, fun, size, fun_in_tenant) do
    ctx = ctx(scope)

    read = fn ->
      case window(ctx.repo, ctx.user_id, schema, after_id, size) do
        [] -> :done
        ids when fun_in_tenant -> {:ran, ids, fun.(ids, ctx, acc)}
        ids -> {:ids, ids}
      end
    end

    stepped =
      case transaction(scope, read, fun_in_tenant) do
        {:ok, {:ids, ids}} -> {:ok, {:ran, ids, fun.(ids, ctx, acc)}}
        other -> other
      end

    case stepped do
      {:ok, :done} ->
        {:ok, acc}

      {:ok, {:ran, ids, {:cont, acc}}} ->
        walk(scope, schema, List.last(ids), acc, fun, size, fun_in_tenant)

      {:ok, {:ran, _ids, {:halt, acc}}} ->
        {:halted, acc}

      {:ok, {:ran, _ids, {:error, _} = err}} ->
        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ctx({:user, user_id}), do: %{repo: Repo, user_id: user_id}
  defp ctx({:fleet, repo}), do: %{repo: repo, user_id: nil}

  # A fleet window read alone needs no transaction (one statement, no tenant
  # to set): skipping it saves a BEGIN/COMMIT round trip per window.
  defp transaction({:fleet, _repo}, fun, false), do: {:ok, fun.()}
  defp transaction({:fleet, repo}, fun, true), do: repo.transaction(fun)
  defp transaction({:user, user_id}, fun, _in_tx), do: Repo.with_tenant(user_id, fun)

  @doc """
  `reduce/5` over every tenant: one fleet walk on the maintenance pool where
  one is configured, else one walk per user in id order
  (`TenantScan.pool/0`), the accumulator threaded through. A halt or an
  error stops the whole walk: the users after it are not visited.

  `:from` (a `t:cursor/0`) resumes a walk: the fleet walk after that key,
  or the per-user walk at that user, after that key, then every later user.
  """
  @spec reduce_all(module(), term(), (list(), ctx(), term() -> step_result()), keyword()) ::
          result()
  def reduce_all(schema, acc, fun, opts \\ []) do
    {from_user, from_after} = Keyword.get(opts, :from) || {nil, nil}
    opts = Keyword.delete(opts, :from)

    case TenantScan.pool() do
      :per_user ->
        TenantScan.user_ids()
        |> Enum.sort()
        |> Enum.drop_while(&(from_user != nil and &1 < from_user))
        |> Enum.reduce_while({:ok, acc}, fn user_id, {:ok, acc} ->
          after_id = if user_id == from_user, do: from_after
          opts = Keyword.put(opts, :after, after_id)

          case walk_scope({:user, user_id}, schema, acc, fun, opts) do
            {:ok, _acc} = ok -> {:cont, ok}
            stop -> {:halt, stop}
          end
        end)
        |> settle()

      {:fleet, maintenance} ->
        # A per-user cursor (the pool changed between passes) restarts.
        after_id = if from_user == nil, do: from_after
        reduce({:fleet, maintenance}, schema, acc, fun, Keyword.put(opts, :after, after_id))
    end
  end

  @doc """
  Every row `query` (a `notes` query, first binding the note) returns, across
  all tenants, asked one id window at a time: the windowed form of
  `TenantScan.all/1` for a rare predicate. Duplicates across windows are the
  caller's to drop (a `distinct` holds within one window).
  """
  @spec all(Ecto.Query.t(), keyword()) :: list()
  def all(%Ecto.Query{} = query, opts \\ []) do
    {:ok, rows} =
      reduce_all(
        Engram.Notes.Note,
        [],
        fn ids, %{repo: repo}, acc ->
          {:cont, [repo.all(where(query, [n], n.id in ^ids)) | acc]}
        end,
        Keyword.put_new(opts, :batch_size, @fleet_window)
      )

    rows |> Enum.reverse() |> Enum.concat()
  end

  @doc "True once `pred.(ids, ctx)` is true for some window of any tenant. Stops there."
  @spec any?(module(), (list(), ctx() -> boolean()), keyword()) :: boolean()
  def any?(schema, pred, opts \\ []) do
    {:ok, found} =
      reduce_all(
        schema,
        false,
        fn ids, ctx, false -> if pred.(ids, ctx), do: {:halt, true}, else: {:cont, false} end,
        opts
      )

    found
  end

  # A pass's time budget. A walk that does not finish in one pass resumes at
  # its cursor on the next (`heal_pass/4`), so the budget bounds one pass,
  # not the walk; the runner's Oban job timeout is 30 min for every ledger
  # migration together.
  @pass_budget_ms 240_000
  # A walk spanning more passes than this logs a warning per pass: the table
  # outgrew the budget, and done now takes that many hourly runs.
  @span_warn_passes 3
  @cursors Engram.Backfill.IdWindows.Cursors

  @doc "Default `:budget_ms` of `heal_pass/4`."
  def pass_budget_ms, do: @pass_budget_ms

  @doc """
  One self-healing data-migration pass (`Engram.DataMigration.run_pass/0`)
  of the walk named `name`: `step.(ids, ctx)` fixes what it can inside one
  window and returns `{fixed, left?}`, where `left?` says a row it matched
  is still unfixed (a row lock it skipped).

  A walk can span passes. A pass stops on its time budget (`:budget_ms`,
  default 240 s) or once `:max_fixed` rows are fixed, and the next pass
  resumes at its cursor instead of window 0, so the tail is reached however
  large the table. `:done` only when ONE complete walk, start to end and
  possibly spanning passes, fixed nothing and left nothing: that walk is the
  completion check, so no fleet-wide EXISTS runs. A walk that found work
  ends and the next pass starts a new one from the start.

  Returns `:done`, or `{:more, rows: fixed}` plus `hit_budget: true` when
  this pass stopped on its time budget. The cursor is node-local (an Agent
  in the application tree, `child_spec/1`), so a restart, or a pass that
  lands on another clustered node, starts the walk over: that costs time,
  never a false done, and the spanning warning shows it if it repeats.
  Takes `reduce/5`'s options.
  """
  @spec heal_pass(
          String.t(),
          module(),
          (list(), ctx() -> {non_neg_integer(), boolean()}),
          keyword()
        ) :: :done | {:more, keyword()}
  def heal_pass(name, schema, step, opts) do
    walk = Agent.get(@cursors, &Map.get(&1, name, %{from: nil, dirty: false, passes: 0}))
    walk = %{walk | passes: walk.passes + 1}
    max_fixed = Keyword.get(opts, :max_fixed, :infinity)

    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @pass_budget_ms)

    # The budget is checked from the second window on: every pass makes
    # progress, so a budget too small for even one window still finishes.
    heal = fn ids, ctx, acc ->
      if acc.windows > 0 and System.monotonic_time(:millisecond) > deadline do
        {:halt, %{acc | stop: :budget}}
      else
        {f, l} = step.(ids, ctx)

        acc = %{
          acc
          | fixed: acc.fixed + f,
            left: acc.left or l,
            windows: acc.windows + 1,
            at: {ctx.user_id, List.last(ids)}
        }

        if acc.fixed >= max_fixed, do: {:halt, %{acc | stop: :cap}}, else: {:cont, acc}
      end
    end

    acc = %{fixed: 0, left: false, stop: nil, at: walk.from, windows: 0}

    pass =
      case reduce_all(schema, acc, heal, Keyword.put(opts, :from, walk.from)) do
        {:ok, pass} -> pass
        {:error, reason} -> raise "id-window pass #{name} failed: #{inspect(reason)}"
      end

    dirty = walk.dirty or pass.fixed > 0 or pass.left

    case pass.stop do
      nil ->
        Agent.update(@cursors, &Map.delete(&1, name))
        if dirty, do: {:more, rows: pass.fixed}, else: :done

      stop ->
        walk = %{walk | from: pass.at, dirty: dirty}
        Agent.update(@cursors, &Map.put(&1, name, walk))
        spanning(name, walk.passes)
        more = [rows: pass.fixed]
        if stop == :budget, do: {:more, more ++ [hit_budget: true]}, else: {:more, more}
    end
  end

  defp spanning(name, passes) when passes > @span_warn_passes do
    :telemetry.execute([:engram, :id_windows, :walk_spanning], %{passes: passes}, %{walk: name})

    Logger.warning(
      "id-window walk #{name} has spanned #{passes} passes without reaching the end",
      Engram.Logger.Metadata.with_category(:warning, :oban, walk: name, passes: passes)
    )
  end

  defp spanning(_name, _passes), do: :ok

  @doc false
  # Drops every walk cursor (tests; `Engram.DataMigrations.reset_cache/0`).
  def reset_walks, do: Agent.update(@cursors, fn _ -> %{} end)

  @doc """
  The walk cursors of `heal_pass/4`, by walk name: one Agent, started in
  the application tree. Not `:persistent_term`, whose every put and erase
  scans the literal area of every process on the node.
  """
  def child_spec(_opts),
    do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> %{} end, [name: @cursors]]}}

  @doc """
  Calls `fun` with each window of the user's row ids (ascending), inside the
  user's tenant context: the per-user sweep DEK rotation
  (`Engram.Crypto.UserDekRotation`) and the envelope re-encode
  (`Engram.Workers.ReencodeEnvelopes`) share. `fun` returns `:ok` to
  continue, `{:halt, value}` to stop early (returned as is, the window
  commits), or `{:error, _}` to stop; the first error is returned. Takes
  `reduce/5`'s options.
  """
  def each_batch(user_id, schema, fun, opts \\ []) do
    step = fn ids, _ctx, nil ->
      case fun.(ids) do
        :ok -> {:cont, nil}
        {:halt, _} = halt -> {:halt, halt}
        {:error, _} = err -> err
      end
    end

    case reduce({:user, user_id}, schema, nil, step, opts) do
      {:ok, nil} -> :ok
      {:ok, halt} -> halt
      {:error, _} = err -> err
    end
  end
end
