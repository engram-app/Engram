defmodule Engram.Bookkeeping.Canary do
  @moduledoc """
  Hourly random-sample proof that the database-kept bookkeeping holds.

  The trigger-closed invariants (derived `notes` keys, the `note_bodies`
  copy, the `note_index_state` row and its chunk counters) are kept by
  database triggers for every writer of every release, so nothing walks the
  table to re-check them. This is the tripwire that replaces the walk: it
  reads a small random sample, runs the checks the old nightly re-verify ran
  (the same predicates, `NoteSplit.unfixed/0`, `NoteSplit.drift_ids/2`,
  `NoteIndexState.drifted/2`) with the deep compare allowed because it is a
  few hundred rows, and reports COUNTS only (never a note id or content).

  Sample: `@points` random positions between the smallest and largest note
  id, `@per_point` consecutive ids from each (a primary-key range read, no
  scan). A random position, not a random uuid, because ids are time-ordered
  (v7): a random 128-bit value would land past the newest note. The ids
  cluster by creation time around each position, so this is a tripwire for
  systematic drift (a disabled trigger, a bad deploy), not a proof of zero:
  with 4,800 sampled rows a day, drift in 0.1% of rows is seen with ~99%
  probability, drift in 0.01% with ~38%.

  `folder_ref` is the app-kept half: `FolderTable` has no nightly re-verify,
  and `Engram.Bookkeeping.Drain` only finds references whose drift its indexes
  describe (a NULL note reference, an attachment reference stamped for another
  path). This counts the references that are wrong anyway: a sampled note
  whose folder row is deleted or is not at its decrypted folder (no index
  can find a reference to a deleted row), and a
  sampled attachment, stamped current, whose decrypted path is not in its
  folder row (a writer that stamped a wrong folder). Users under a DEK
  rotation are skipped: their rows and folder rows are re-keyed in separate
  sweeps, so a mid-rotation compare would report drift that is not there. Attachments are
  sampled like notes, on their own ids; their paths are decrypted under each
  sampled user's key, counts only leave this module.

  `body_drift` compares each `notes` body column with its `note_bodies` copy.
  It is meaningful only while `notes` still carries the body columns: once
  the R8 contract (#2402) drops them there is nothing to compare, and the
  invariant reads 0 by construction; remove it with that contract.

  Telemetry (`Engram.PromEx.Reliability`):
    * `[:engram, :bookkeeping, :drift]` `%{count: n}` tagged `:invariant`,
      one event per invariant per run (0 included):
      `engram_prom_ex_reliability_bookkeeping_drift_total`.
    * `[:engram, :bookkeeping, :canary_rows]` `%{count: n}`: rows checked
      (`engram_prom_ex_reliability_bookkeeping_canary_rows_total`).
    * `[:engram, :bookkeeping, :canary_ran]` `%{unix: s}`: when the run
      finished (`engram_prom_ex_reliability_bookkeeping_canary_last_run_unix`,
      a gauge). The dead-man signal: a canary that stops running must not
      look healthy.

  Scope follows `TenantScan.pool/0`: one fleet sample on the maintenance pool
  (SaaS), else a share of the sample per user inside that user's tenant
  (self-host).
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.DataMigrations.NoteIndexState
  alias Engram.DataMigrations.NoteSplit
  alias Engram.Folders.Rows
  alias Engram.Logger.Metadata
  alias Engram.Notes.Helpers
  alias Engram.Repo

  require Logger

  @points 20
  @per_point 10

  @invariants [:note_split, :body_drift, :state_missing, :counters_drift, :folder_ref]

  @doc "The invariant tags the canary reports, in a stable order."
  @spec invariants() :: [invariant(), ...]
  def invariants, do: @invariants

  @type invariant ::
          :note_split | :body_drift | :state_missing | :counters_drift | :folder_ref
  @type report :: %{checked: non_neg_integer(), drift: %{invariant() => non_neg_integer()}}

  @doc """
  One canary run: sample, check, emit telemetry, log counts. Returns the
  report. `:points` / `:per_point` shrink the sample (tests).
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    points = Keyword.get(opts, :points, @points)
    per_point = Keyword.get(opts, :per_point, @per_point)

    report =
      scoped(points, fn repo, user_id, share ->
        ids = sample(repo, "notes", user_id, share, per_point)
        att_ids = sample(repo, "attachments", user_id, share, per_point)
        drift = check(repo, ids)

        {length(ids) + length(att_ids),
         %{drift | folder_ref: drift.folder_ref + wrong_attachment_refs(repo, att_ids)}}
      end)
      |> Enum.reduce(%{checked: 0, drift: zero()}, fn {n, drift}, acc ->
        %{checked: acc.checked + n, drift: Map.merge(acc.drift, drift, fn _, a, b -> a + b end)}
      end)

    emit(report)
    report
  end

  defp zero, do: Map.new(@invariants, &{&1, 0})

  # The checks of the removed nightly re-verifies, on `ids` only.
  defp check(_repo, []), do: zero()

  defp check(repo, ids) do
    {drifted, missing} = NoteIndexState.drifted(repo, Enum.map(ids, &Ecto.UUID.dump!/1))

    %{
      note_split: length(NoteSplit.unfixed_ids(repo, ids)),
      body_drift: length(NoteSplit.drift_ids(repo, ids)),
      state_missing: missing,
      counters_drift: length(drifted),
      folder_ref: wrong_note_refs(repo, ids)
    }
  end

  # Live notes whose reference names a deleted folder row, or a live one of
  # another path. A NULL reference (no row yet) is the drain's. The path is
  # the note's decrypted folder envelope, never `notes.folder_hmac`, which a
  # note may not carry (R9): one decrypt per sampled note with a reference.
  defp wrong_note_refs(repo, ids) do
    from(n in "notes",
      as: :a,
      left_join: f in "folders",
      on: f.id == n.folder_ref_id and is_nil(f.deleted_at) and f.vault_id == n.vault_id,
      where:
        n.id in type(^ids, {:array, Ecto.UUID}) and n.kind == "note" and is_nil(n.deleted_at) and
          not is_nil(n.folder_ref_id) and not exists(rotating()),
      select: %{
        id: n.id,
        user_id: type(n.user_id, Ecto.UUID),
        dek_version: n.dek_version,
        ct: n.folder_ciphertext,
        nonce: n.folder_nonce,
        ref: n.folder_ref_id,
        folder_live?: not is_nil(f.id),
        folder_hmac: f.full_path_hmac
      }
    )
    |> repo.all()
    |> count_wrong_by_user(repo, fn row, dek ->
      Rows.decrypt_field(dek, :notes, :folder, row.id, row.dek_version, row.ct, row.nonce)
    end)
  end

  # The sampled row's (bound as `:a`) user is mid DEK rotation.
  defp rotating do
    from(u in "users",
      where: u.id == parent_as(:a).user_id and not is_nil(u.dek_rotation_locked_at),
      select: 1
    )
  end

  # Live attachments a reader trusts (stamp current) whose decrypted path is not
  # in the folder row they name (or that name one at the root).
  defp wrong_attachment_refs(_repo, []), do: 0

  defp wrong_attachment_refs(repo, ids) do
    from(a in "attachments",
      as: :a,
      left_join: f in "folders",
      on: f.id == a.folder_ref_id and is_nil(f.deleted_at),
      where: a.id in type(^ids, {:array, Ecto.UUID}) and is_nil(a.deleted_at),
      where: ^Rows.attachment_ref_current(),
      where: is_nil(a.dek_version_pending) and not exists(rotating()),
      select: %{
        id: type(a.id, Ecto.UUID),
        user_id: type(a.user_id, Ecto.UUID),
        dek_version: a.dek_version,
        path_ciphertext: a.path_ciphertext,
        path_nonce: a.path_nonce,
        ref: a.folder_ref_id,
        folder_live?: not is_nil(f.id),
        folder_hmac: f.full_path_hmac
      }
    )
    |> repo.all()
    |> count_wrong_by_user(repo, fn row, dek ->
      id = Ecto.UUID.dump!(row.id)

      with {:ok, path} <-
             Rows.decrypt_field(
               dek,
               :attachments,
               :path,
               id,
               row.dek_version,
               row.path_ciphertext,
               row.path_nonce
             ),
           do: {:ok, Helpers.extract_folder(path)}
    end)
  end

  # Per sampled user, the rows whose decrypted folder (`folder_of.(row, dek)`)
  # is not their folder row's path. A folder that does not decrypt is not
  # judged here (the drain's warning owns it).
  defp count_wrong_by_user(rows, repo, folder_of) do
    rows
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {user_id, rows} -> count_wrong(repo, user_id, rows, folder_of) end)
    |> Enum.sum()
  end

  defp count_wrong(repo, user_id, rows, folder_of) do
    with %User{} = user <- repo.get(User, user_id),
         {:ok, dek} <- Crypto.get_dek(user) do
      fk = Crypto.dek_filter_key_from_bytes(dek)

      Enum.count(rows, fn row ->
        case folder_of.(row, dek) do
          {:ok, folder} -> wrong_ref?(row, folder, fk)
          :error -> false
        end
      end)
    else
      _ -> 0
    end
  end

  defp wrong_ref?(row, "", _fk), do: row.ref != nil
  defp wrong_ref?(%{folder_live?: false}, _folder, _fk), do: true
  defp wrong_ref?(row, folder, fk), do: row.folder_hmac != Rows.path_hmac(fk, folder)

  # ---- sampling ------------------------------------------------------------

  # `fun.(repo, user_id | nil, points)` once on the fleet, or once per user in
  # that user's tenant with an equal share of the points. The users with the
  # most share are not favoured: `Enum.shuffle/1` bounds the work to `points`
  # users.
  defp scoped(points, fun) do
    case TenantScan.pool() do
      {:fleet, repo} ->
        [fun.(repo, nil, points)]

      :per_user ->
        users = TenantScan.user_ids() |> Enum.shuffle() |> Enum.take(points)
        share = max(div(points, max(length(users), 1)), 1)
        Enum.map(users, fn uid -> Repo.with_tenant!(uid, fn -> fun.(Repo, uid, share) end) end)
    end
  end

  defp sample(repo, table, user_id, points, per_point) do
    with lo when is_binary(lo) <- edge(repo, table, user_id, :asc),
         hi when is_binary(hi) <- edge(repo, table, user_id, :desc) do
      {lo, hi} = {to_int(lo), to_int(hi)}

      # The smallest id is always a position, so a table of at most `per_point`
      # notes is checked whole.
      positions = [lo | for(_ <- 2..points//1, do: lo + :rand.uniform(hi - lo + 1) - 1)]

      positions
      |> Enum.flat_map(&from_point(repo, table, user_id, &1, per_point))
      |> Enum.uniq()
    else
      nil -> []
    end
  end

  defp edge(repo, table, user_id, dir) do
    from(n in table, order_by: [{^dir, n.id}], limit: 1, select: type(n.id, Ecto.UUID))
    |> scope(user_id)
    |> repo.one()
  end

  defp from_point(repo, table, user_id, at, per_point) do
    from(n in table,
      where: n.id >= type(^from_int(at), Ecto.UUID),
      order_by: n.id,
      limit: ^per_point,
      select: type(n.id, Ecto.UUID)
    )
    |> scope(user_id)
    |> repo.all()
  end

  defp scope(query, nil), do: query
  defp scope(query, user_id), do: where(query, [n], n.user_id == type(^user_id, Ecto.UUID))

  defp to_int(id), do: Ecto.UUID.dump!(id) |> then(fn <<n::128>> -> n end)
  defp from_int(n), do: Ecto.UUID.load!(<<n::128>>)

  # ---- reporting -----------------------------------------------------------

  defp emit(%{checked: checked, drift: drift}) do
    :telemetry.execute([:engram, :bookkeeping, :canary_rows], %{count: checked}, %{})

    :telemetry.execute(
      [:engram, :bookkeeping, :canary_ran],
      %{unix: System.system_time(:second)},
      %{}
    )

    for {invariant, n} <- drift,
        do:
          :telemetry.execute([:engram, :bookkeeping, :drift], %{count: n}, %{invariant: invariant})

    found = for {invariant, n} <- drift, n > 0, do: {invariant, n}

    if found == [] do
      Logger.info(
        "bookkeeping canary clean",
        Metadata.with_category(:info, :oban, checked: checked)
      )
    else
      Logger.warning(
        "bookkeeping canary found drift (counts only)",
        Metadata.with_category(:warning, :oban, [checked: checked] ++ found)
      )
    end
  end
end
