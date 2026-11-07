defmodule Engram.Workers.BackfillNoteNames do
  @moduledoc """
  The `NoteName` backfill (O(1) folder rename plan S2): one fleet-wide chain
  that walks `notes`, `attachments` and `folders` in primary-key windows
  (`Engram.Backfill.IdWindows`) and fills each row's name columns where they
  are missing or stale (`Engram.Notes.Name`, `Engram.Folders.Folder.name_keys/3`).
  Started by `Engram.DataMigrations.NoteName`.

  ## Pace

  A hop (`Engram.Backfill.PacedChain.walk/5`) fixes at most
  `NoteName.max_rows/0` rows (default 500) or works 30 s, whichever is first,
  then schedules its successor 45 s out with its cursor in
  the args, so the lane (`:crdt_backfill`, concurrency 1) is free between
  hops and the database sees short bursts: about 600 rows a minute at most.
  ~67k prod notes plus their tombstones and attachments: about 2-3 h. A window
  is 100 ids; each is one transaction under `lock_timeout = '2s'`: one probe of
  its stale rows, then one UPDATE of the rows it fixed. Writes only the name
  columns (no `updated_at`, `seq` or fan-out).

  ## Correctness

  Each name is derived from the ciphertext it describes and written with a
  compare-and-set on that ciphertext's nonce (`path_nonce`, or the folder's
  `name_nonce`), so a concurrent rename wins and its row is left for the next
  walk. A user mid DEK rotation is skipped (left). A row that never decrypts is
  logged and left.

  ## Done

  A walk spans hops (the cursor is in the args, so a hop may run on any node).
  At the end of the last table: a walk that fixed rows starts a new walk; a
  walk that fixed nothing and left nothing marks the ledger done; a walk that
  only left rows stops the chain (the next hourly runner pass starts a new
  one). The kill switch is read before every window: off stops the hop at
  once, with no successor.
  """
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: Engram.Jobs.unique(__MODULE__)

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Backfill.{IdWindows, PacedChain}
  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, PathCrypto, RotationGate}
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteName
  alias Engram.Folders.{Folder, Rows}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Name, Note}
  alias Engram.Repo

  require Logger

  @tables [:notes, :attachments, :folders]
  @batch_size 100
  @budget_ms 30_000
  @pace_s 45

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if NoteName.enabled?() do
      case hop(args, max_rows: NoteName.max_rows()) do
        {:next, next} ->
          {:ok, _} = Oban.insert(new(next, schedule_in: @pace_s))
          :ok

        _done_or_stopped ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  One hop of the chain from `args` (a fresh walk for `%{}`). Returns
  `{:next, args}` for the successor, `:done` (ledger marked done) or
  `:stopped`. Options (tests): `:max_rows`, `:batch_size`, `:budget_ms`.
  """
  @spec hop(map(), keyword()) :: {:next, map()} | :done | :stopped
  def hop(args, opts \\ []) do
    st = %{
      t: args["t"] || 0,
      from: decode(args["from"]),
      walk_fixed: args["fixed"] == true,
      walk_left: args["left"] == true,
      hop_fixed: 0,
      windows: 0
    }

    o = %{
      max_rows: Keyword.get(opts, :max_rows, NoteName.max_rows()),
      batch: Keyword.get(opts, :batch_size, @batch_size),
      deadline: PacedChain.deadline(Keyword.get(opts, :budget_ms, @budget_ms))
    }

    result = walk(st, o)
    log(result, st.t)
    elem(result, 0)
  end

  defp walk(%{t: t} = st, _o) when t >= length(@tables), do: finish(st)

  defp walk(st, o) do
    table = Enum.at(@tables, st.t)

    step = fn ids, ctx, st ->
      {fixed, left} = heal_window(table, ids, ctx)

      %{
        st
        | hop_fixed: st.hop_fixed + fixed,
          windows: st.windows + 1,
          walk_fixed: st.walk_fixed or fixed > 0,
          walk_left: st.walk_left or left
      }
    end

    stop? = fn st -> st.hop_fixed >= o.max_rows or PacedChain.past?(o.deadline) end

    case PacedChain.walk(schema(table), st.from, st, step,
           stop?: stop?,
           continue?: &NoteName.enabled?/0,
           batch_size: o.batch,
           fun_in_tenant: false
         ) do
      {:aborted, st} -> {:stopped, st}
      {:stopped, at, st} -> {{:next, args(%{st | from: at})}, st}
      {:walked, st} -> walk(%{st | t: st.t + 1, from: nil}, o)
    end
  end

  defp finish(%{walk_fixed: true} = st),
    do: {{:next, %{"t" => 0, "from" => nil, "fixed" => false, "left" => false}}, st}

  defp finish(%{walk_left: true} = st), do: {:stopped, st}

  defp finish(st) do
    :ok = DataMigrations.mark_done(NoteName.name(), NoteName.version())
    {:done, st}
  end

  defp args(st),
    do: %{
      "t" => st.t,
      "from" => encode(st.from),
      "fixed" => st.walk_fixed,
      "left" => st.walk_left
    }

  defp encode(nil), do: nil
  defp encode({user_id, after_id}), do: [user_id, after_id]

  defp decode(nil), do: nil
  defp decode([user_id, after_id]), do: {user_id, after_id}

  defp schema(:notes), do: Note
  defp schema(:attachments), do: Attachment
  defp schema(:folders), do: Folder

  defp log({result, st}, first_table) do
    Logger.info(
      "note name backfill hop",
      Metadata.with_category(:info, :oban,
        result: elem_result(result),
        fixed: st.hop_fixed,
        windows: st.windows,
        from_table: Enum.at(@tables, first_table),
        walk_fixed: st.walk_fixed,
        walk_left: st.walk_left
      )
    )
  end

  defp elem_result({:next, _}), do: :next
  defp elem_result(other), do: other

  @doc """
  Heals the stale rows among `ids` of `table` in one transaction: the
  owner's tenant for a per-user walk, the maintenance pool's for the fleet
  walk. Returns `{fixed, left?}`. Public for the RLS test.
  """
  @spec heal_window(atom(), [Ecto.UUID.t()], IdWindows.ctx()) :: {non_neg_integer(), boolean()}
  def heal_window(table, ids, %{repo: repo, user_id: user_id}) do
    {:ok, result} =
      in_tx(repo, user_id, fn ->
        _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
        rows = repo.all(IdWindows.by_id(stale(table), ids))
        {fixes, left} = derive(table, rows)
        fixed = write(table, repo, fixes)
        {fixed, left or fixed < length(fixes)}
      end)

    result
  end

  defp in_tx(repo, nil, fun), do: repo.transaction(fun)
  defp in_tx(_repo, user_id, fun), do: Repo.with_tenant(user_id, fun)

  # The rows whose name columns do not describe their current source
  # ciphertext: never written, or stamped for another nonce or version.
  defp stale(:folders) do
    from(f in Folder,
      where:
        not is_nil(f.name_ciphertext) and
          fragment(
            "? IS DISTINCT FROM (? || ?::bytea)",
            f.name_stamp,
            f.name_nonce,
            ^Name.version()
          ),
      select: %{
        id: f.id,
        user_id: f.user_id,
        dek_version: f.dek_version,
        ct: f.name_ciphertext,
        nonce: f.name_nonce
      }
    )
  end

  defp stale(table) do
    from(r in schema(table),
      where:
        not is_nil(r.path_ciphertext) and
          fragment(
            "? IS DISTINCT FROM (? || ?::bytea)",
            r.name_stamp,
            r.path_nonce,
            ^Name.version()
          ),
      select: %{
        id: r.id,
        user_id: r.user_id,
        dek_version: r.dek_version,
        ct: r.path_ciphertext,
        nonce: r.path_nonce
      }
    )
    |> notes_only(table)
  end

  # Markers (`kind = 'folder'`) become folder rows at contract; they get no name.
  defp notes_only(query, :notes), do: where(query, [n], n.kind == "note")
  defp notes_only(query, _table), do: query

  # `{fixes, left?}`: each row's new columns, from its owner's DEK.
  defp derive(_table, []), do: {[], false}

  defp derive(table, rows) do
    user_ids = rows |> Enum.map(& &1.user_id) |> Enum.uniq()
    users = Map.new(Repo.all(from(u in User, where: u.id in ^user_ids)), &{&1.id, &1})

    rows
    |> Enum.group_by(& &1.user_id)
    |> Enum.reduce({[], false}, fn {user_id, rows}, {fixes, left} ->
      with %User{} = user <- users[user_id],
           :ok <- RotationGate.check_user(user),
           {:ok, dek} <- Crypto.get_dek(user) do
        fk = Crypto.dek_filter_key_from_bytes(dek)
        {mine, unread} = Enum.split_with(Enum.map(rows, &fix(table, &1, dek, fk)), &is_map/1)
        {mine ++ fixes, left or unread != []}
      else
        _ -> {fixes, true}
      end
    end)
  end

  defp fix(table, row, dek, fk) do
    case decrypt(table, row, dek) do
      {:ok, plain} ->
        %{id: row.id, src: row.nonce, cols: cols(table, row, plain, dek, fk)}

      :error ->
        Logger.warning(
          "note name backfill: row does not decrypt, left unnamed",
          Metadata.with_category(:warning, :crypto, table: table, row_id: row.id)
        )

        :error
    end
  end

  defp decrypt(:folders, row, dek),
    do: Rows.decrypt_name(dek, row.id, row.dek_version, row.ct, row.nonce)

  defp decrypt(table, row, dek),
    do: Envelope.decrypt(row.ct, row.nonce, dek, PathCrypto.aad(table, row.id, row.dek_version))

  defp cols(:folders, row, segment, _dek, fk),
    do: Keyword.delete(Folder.name_keys(fk, segment, row.nonce), :name_hmac)

  defp cols(table, row, path, dek, fk), do: Name.keys(table, dek, fk, row.id, path, row.nonce)

  defp write(_table, _repo, []), do: 0

  defp write(:folders, repo, fixes) do
    {ids, srcs, cols} = columns(fixes)

    {n, _} =
      from(f in Folder,
        join:
          v in fragment(
            "SELECT * FROM unnest(?::uuid[], ?::bytea[], ?::bytea[], ?::bytea[]) AS t(id, src, ci, stamp)",
            ^ids,
            ^srcs,
            ^cols.name_ci_hmac,
            ^cols.name_stamp
          ),
        on: f.id == field(v, :id) and f.name_nonce == field(v, :src),
        update: [set: [name_ci_hmac: field(v, :ci), name_stamp: field(v, :stamp)]]
      )
      |> repo.update_all([])

    n
  end

  defp write(table, repo, fixes) do
    {ids, srcs, cols} = columns(fixes)

    {n, _} =
      from(r in schema(table),
        join:
          v in fragment(
            "SELECT * FROM unnest(?::uuid[], ?::bytea[], ?::bytea[], ?::bytea[], ?::bytea[], ?::bytea[], ?::bytea[]) AS t(id, src, ct, nonce, h, ci, stamp)",
            ^ids,
            ^srcs,
            ^cols.name_ciphertext,
            ^cols.name_nonce,
            ^cols.name_hmac,
            ^cols.name_ci_hmac,
            ^cols.name_stamp
          ),
        on: r.id == field(v, :id) and r.path_nonce == field(v, :src),
        update: [
          set: [
            name_ciphertext: field(v, :ct),
            name_nonce: field(v, :nonce),
            name_hmac: field(v, :h),
            name_ci_hmac: field(v, :ci),
            name_stamp: field(v, :stamp)
          ]
        ]
      )
      |> repo.update_all([])

    n
  end

  # Column-major arrays for the unnest: ids, CAS nonces and each name column.
  defp columns(fixes) do
    ids = Enum.map(fixes, &Ecto.UUID.dump!(&1.id))
    srcs = Enum.map(fixes, & &1.src)
    keys = fixes |> hd() |> Map.fetch!(:cols) |> Keyword.keys()
    cols = Map.new(keys, fn k -> {k, Enum.map(fixes, &Keyword.fetch!(&1.cols, k))} end)
    {ids, srcs, cols}
  end
end
