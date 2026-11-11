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
  pausing `PacedChain.pause_ms/0` (250 ms) after every window, so a clean
  window costs the database a few statements four times a second at most and
  a hop reads at most about 120 windows. It then schedules its successor 45 s
  out with its cursor in the args, so the lane (`:crdt_backfill`,
  concurrency 1) is free between hops. Inside a hop the walk also keeps to
  `NoteName.writes_per_s/0` rows a second (default 150,
  `Engram.Backfill.Throttle`), and before a hop the pressure gate
  (`Throttle.pressure/0`: app pool queue, oldest open transaction) can hold
  it: the same hop is re-inserted 45 s later and writes nothing. About 600 rows a minute at most;
  ~67k prod notes plus their tombstones and attachments: about 3 h (estimate,
  not measured). A window is 100 ids, one transaction under
  `lock_timeout = '2s'`: one probe of its stale rows, one
  `FOR NO KEY UPDATE SKIP LOCKED` of those (a row a user's write holds is
  skipped and counts as left, never waited on), then one UPDATE. Writes only
  the name columns (no `updated_at`, `seq` or fan-out), none of them indexed,
  so the update can stay heap-only.

  ## Correctness

  Each name is derived from the ciphertext it describes and written with a
  compare-and-set on that ciphertext's nonce (`path_nonce`, or the folder's
  `name_nonce`), so a concurrent rename wins and its row is left for the next
  walk. Rows whose owner's key does not load are classified by
  `Crypto.key_outcome/1`: only an owner who is gone, has no key or holds a
  wrapped key that is provably not one is parked; anything else (a rotation
  in progress, a KMS error, a load timeout, a wrapping the current master key
  does not open) is deferred: left untouched, logged and counted
  (`[:engram, :note_name, :deferred]`), retried by the next walk. A row that
  never decrypts is stamped `NameKeys.unreadable/1` of its stamp, logged and
  counted (`[:engram, :note_name, :skipped]`): it leaves
  the stale set, so it cannot hold the ledger open, until a writer gives it a
  fresh ciphertext (the skip path `Engram.Search.NameTerms` uses).

  ## Done

  A walk spans hops (the cursor is in the args, so a hop may run on any node).
  At the end of the last table: a walk that fixed or parked rows starts a new
  walk; a walk that fixed nothing and left nothing marks the ledger done; a
  walk that only left rows stops the chain and is recorded
  (`NoteName.walked/1`), so the next full walk waits a day. A walk starts,
  and the ledger closes, only while every cluster node writes names (`NoteName.fleet_ready?/1`, `Readiness.peers_report/4`),
  so no older node can add unnamed rows behind the closing walk's cursor. The
  kill switch is read before every window: off stops the hop at once, with no
  successor.
  """
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: Engram.Jobs.unique(__MODULE__)

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Backfill.{IdWindows, PacedChain, Throttle}
  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, NameKeys, PathCrypto, RotationGate}
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
    cond do
      not NoteName.enabled?() ->
        :ok

      # Held on database pressure: the same hop, later, nothing written now.
      reason = Throttle.pressure() ->
        {:ok, _} = Oban.insert(new(args, schedule_in: @pace_s))
        Throttle.log_pass("note_name", written: 0, held: reason, elapsed_ms: 0)

      true ->
        case hop(args, max_rows: NoteName.max_rows()) do
          {:next, next} ->
            {:ok, _} = Oban.insert(new(next, schedule_in: @pace_s))
            :ok

          _done_or_stopped ->
            :ok
        end
    end
  end

  @doc """
  One hop of the chain from `args` (a fresh walk for `%{}`). Returns
  `{:next, args}` for the successor, `:done` (ledger marked done) or
  `:stopped`. Options (tests): `:max_rows`, `:writes_per_s`, `:batch_size`,
  `:budget_ms`, `:pause_ms`, `:fleet` (`NoteName.fleet_ready?/1`).
  """
  @spec hop(map(), keyword()) :: {:next, map()} | :done | :stopped
  def hop(args, opts \\ []) do
    fleet = Keyword.get(opts, :fleet, [])

    if walk_start?(args) and not NoteName.fleet_ready?(fleet) do
      :stopped
    else
      do_hop(args, opts, fleet)
    end
  end

  defp walk_start?(args), do: (args["t"] || 0) == 0 and is_nil(args["from"])

  defp do_hop(args, opts, fleet) do
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
      writes_per_s: Keyword.get(opts, :writes_per_s, NoteName.writes_per_s()),
      batch: Keyword.get(opts, :batch_size, @batch_size),
      deadline: PacedChain.deadline(Keyword.get(opts, :budget_ms, @budget_ms)),
      pause_ms: Keyword.get(opts, :pause_ms, PacedChain.pause_ms()),
      fleet: fleet
    }

    started = Throttle.now_ms()
    result = walk(st, o)
    log(result, st.t, started)
    elem(result, 0)
  end

  defp walk(%{t: t} = st, o) when t >= length(@tables), do: finish(st, o.fleet)

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
           pause_ms: o.pause_ms,
           writes: & &1.hop_fixed,
           writes_per_s: o.writes_per_s,
           batch_size: o.batch,
           fun_in_tenant: false
         ) do
      {:aborted, st} -> {:stopped, st}
      {:stopped, at, st} -> {{:next, args(%{st | from: at})}, st}
      {:walked, st} -> walk(%{st | t: st.t + 1, from: nil}, o)
    end
  end

  defp finish(%{walk_fixed: true} = st, _fleet),
    do: {{:next, %{"t" => 0, "from" => nil, "fixed" => false, "left" => false}}, st}

  # Fixed nothing, left rows: record it, so the ledger waits a day before the
  # next full walk (`NoteName.run_pass/0`).
  defp finish(%{walk_left: true} = st, _fleet) do
    :ok = NoteName.walked(0)
    {:stopped, st}
  end

  # A clean walk closes the ledger only if no older node joined meanwhile.
  defp finish(st, fleet) do
    if NoteName.fleet_ready?(fleet) do
      :ok = DataMigrations.mark_done(NoteName.name(), NoteName.version())
      {:done, st}
    else
      {:stopped, st}
    end
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

  # The pass line (`Throttle.log_pass/2`). Rows left are not counted: the
  # name columns have no index, so a count would walk the table; `walk_left`
  # says whether this walk has left any behind.
  defp log({result, st}, first_table, started) do
    Throttle.log_pass("note_name",
      written: st.hop_fixed,
      held: :none,
      elapsed_ms: Throttle.now_ms() - started,
      result: elem_result(result),
      windows: st.windows,
      from_table: Enum.at(@tables, first_table),
      walk_fixed: st.walk_fixed,
      walk_left: st.walk_left
    )
  end

  defp elem_result({:next, _}), do: :next
  defp elem_result(other), do: other

  @doc """
  Heals the stale rows among `ids` of `table` in one transaction: the
  owner's tenant for a per-user walk, the maintenance pool's for the fleet
  walk. Returns `{handled, left?}`: rows named or parked, and whether a
  stale row was left (held by another writer, lost its compare-and-set, or
  its owner is mid rotation). Public for the RLS and fleet tests.
  """
  @spec heal_window(atom(), [Ecto.UUID.t()], IdWindows.ctx()) :: {non_neg_integer(), boolean()}
  def heal_window(table, ids, %{repo: repo, user_id: user_id}) do
    {:ok, result} =
      in_tx(repo, user_id, fn ->
        _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
        stale = repo.all(IdWindows.by_id(stale(table), ids))
        locked = unheld(table, repo, stale)
        {fixes, parks, left} = derive(table, locked)
        written = write(table, repo, fixes) + park(table, repo, parks)

        {written,
         left or length(locked) < length(stale) or written < length(fixes) + length(parks)}
      end)

    result
  end

  defp in_tx(repo, nil, fun), do: repo.transaction(fun)
  defp in_tx(_repo, user_id, fun), do: Repo.with_tenant(user_id, fun)

  # The stale rows nobody else holds: a row a user's write has locked is
  # skipped, never waited on.
  defp unheld(_table, _repo, []), do: []

  defp unheld(table, repo, rows) do
    ids = Enum.map(rows, & &1.id)

    held =
      from(r in schema(table),
        where: r.id in ^ids,
        lock: "FOR NO KEY UPDATE SKIP LOCKED",
        select: r.id
      )
      |> repo.all()
      |> MapSet.new()

    Enum.filter(rows, &MapSet.member?(held, &1.id))
  end

  # The rows whose name keys do not describe their current source
  # ciphertext: never written, or stamped for another nonce or version. A
  # row parked as unreadable for its current source is not stale.
  defp stale(table) do
    {ct, nonce} = source(table)
    v = Name.version()

    from(r in schema(table),
      where:
        not is_nil(field(r, ^ct)) and
          fragment("? IS DISTINCT FROM (? || ?::bytea)", r.name_stamp, field(r, ^nonce), ^v) and
          fragment(
            "? IS DISTINCT FROM ('\\x00'::bytea || ? || ?::bytea)",
            r.name_stamp,
            field(r, ^nonce),
            ^v
          ),
      select: %{
        id: r.id,
        user_id: r.user_id,
        dek_version: r.dek_version,
        ct: field(r, ^ct),
        nonce: field(r, ^nonce)
      }
    )
    |> notes_only(table)
  end

  defp source(:folders), do: {:name_ciphertext, :name_nonce}
  defp source(_table), do: {:path_ciphertext, :path_nonce}

  # Markers (`kind = 'folder'`) become folder rows at contract; they get no name.
  defp notes_only(query, :notes), do: where(query, [n], n.kind == "note")
  defp notes_only(query, _table), do: query

  # `{fixes, parks, left?}`: each readable row's new columns from its owner's
  # DEK, and the rows to park as unreadable.
  defp derive(_table, []), do: {[], [], false}

  defp derive(table, rows) do
    user_ids = rows |> Enum.map(& &1.user_id) |> Enum.uniq()
    users = Map.new(Repo.all(from(u in User, where: u.id in ^user_ids)), &{&1.id, &1})

    rows
    |> Enum.group_by(& &1.user_id)
    |> Enum.reduce({[], [], false}, fn {user_id, rows}, {fixes, parks, left} ->
      case user_dek(users[user_id]) do
        {:ok, dek} ->
          fk = Crypto.dek_filter_key_from_bytes(dek)

          {mine, unread} =
            rows |> Enum.map(&fix(table, &1, dek, fk)) |> Enum.split_with(&is_map/1)

          {mine ++ fixes, Enum.map(unread, &{elem(&1, 1), :undecryptable}) ++ parks, left}

        {:later, reason} ->
          deferred(table, user_id, length(rows), reason)
          {fixes, parks, true}

        {:park, reason} ->
          {fixes, Enum.map(rows, &{&1, reason}) ++ parks, left}
      end
    end)
  end

  # The owner's DEK, or what to do with their rows when it does not load:
  # `Crypto.key_outcome/1` (shared with `Engram.Search.NameTerms`) parks only
  # rows that can never be read (owner gone, no key, a wrapped key that is
  # provably not one); everything else, a rotation in progress included, is
  # `:later`: the rows are left untouched and the next walk retries them.
  # Each with its bounded label (`Crypto.key_reason/1`).
  defp user_dek(user) do
    with %User{} <- user,
         :ok <- RotationGate.check_user(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      {:ok, dek}
    else
      failed -> {Crypto.key_outcome(failed), Crypto.key_reason(failed)}
    end
  end

  # Exported as `engram_prom_ex_search_note_name_deferred_total{reason}`.
  defp deferred(table, user_id, count, reason) do
    :telemetry.execute([:engram, :note_name, :deferred], %{count: count}, %{
      reason: reason,
      table: table
    })

    Logger.warning(
      "note name backfill: owner key unavailable, rows deferred",
      Metadata.with_category(:warning, :crypto,
        table: table,
        user_id: user_id,
        reason_label: reason,
        total_count: count
      )
    )
  end

  defp fix(table, row, dek, fk) do
    case decrypt(table, row, dek) do
      {:ok, plain} -> %{id: row.id, src: row.nonce, cols: cols(table, row, plain, dek, fk)}
      :error -> {:unreadable, row}
    end
  end

  defp decrypt(:folders, row, dek),
    do: Rows.decrypt_name(dek, row.id, row.dek_version, row.ct, row.nonce)

  defp decrypt(table, row, dek),
    do: Envelope.decrypt(row.ct, row.nonce, dek, PathCrypto.aad(table, row.id, row.dek_version))

  defp cols(:folders, row, segment, _dek, fk),
    do: Keyword.delete(Folder.name_keys(fk, segment, row.nonce), :name_hmac)

  defp cols(table, row, path, dek, fk), do: Name.keys(table, dek, fk, row.id, path, row.nonce)

  @doc false
  # The compare-and-set write: each fix lands only while the row still holds
  # the source nonce it was derived from. Public for the CAS test.
  @spec write(atom(), module(), [map()]) :: non_neg_integer()
  def write(_table, _repo, []), do: 0

  def write(:folders, repo, fixes) do
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

  def write(table, repo, fixes) do
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

  # Unreadable rows: stamped out of the stale set (same compare-and-set on
  # the source nonce), logged and counted.
  defp park(_table, _repo, []), do: 0

  defp park(table, repo, parks) do
    parks
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.map(fn {reason, rows} -> park(table, repo, rows, reason) end)
    |> Enum.sum()
  end

  # Exported as `engram_prom_ex_search_note_name_skipped_total{reason}`.
  defp park(table, repo, rows, reason) do
    {_ct, nonce_col} = source(table)
    ids = Enum.map(rows, &Ecto.UUID.dump!(&1.id))
    srcs = Enum.map(rows, & &1.nonce)
    stamps = Enum.map(rows, &NameKeys.unreadable(Name.stamp(&1.nonce)))

    {n, _} =
      from(r in schema(table),
        join:
          v in fragment(
            "SELECT * FROM unnest(?::uuid[], ?::bytea[], ?::bytea[]) AS t(id, src, stamp)",
            ^ids,
            ^srcs,
            ^stamps
          ),
        on: r.id == field(v, :id) and field(r, ^nonce_col) == field(v, :src),
        update: [set: [name_stamp: field(v, :stamp)]]
      )
      |> repo.update_all([])

    :telemetry.execute([:engram, :note_name, :skipped], %{count: n}, %{
      reason: reason,
      table: table
    })

    Logger.warning(
      "note name backfill: rows parked unnamed",
      Metadata.with_category(:warning, :crypto,
        table: table,
        reason_label: reason,
        total_count: n
      )
    )

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
