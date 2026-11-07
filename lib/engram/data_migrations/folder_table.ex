defmodule Engram.DataMigrations.FolderTable do
  @moduledoc """
  Fills the `folders` table and `folder_ref_id` for rows written before the
  `notes_set_folder_ref` trigger and folder rows existed (migrations
  20261029000000..800). Every later note write resolves its own folder in
  the database, so this only catches up and heals what a previous-release
  writer left behind. No daily re-verify: `Engram.Bookkeeping.Drain` finds the
  users with drift through partial indexes and runs `run_pass/1` for them.

  Per user, through the maintenance pool where one is configured (SaaS) and
  per tenant otherwise, like `NoteSplit` (`TenantScan`):

    1. `kind = 'folder'` marker rows become `explicit` folders that KEEP the
       marker's UUID, so web and plugin ids stay stable.
    2. Notes: each unresolved note (no reference, or one to a dead row) in
       a non-root folder, a page of 1,000 at a time, has its own folder
       envelope decrypted (never `notes.folder_hmac`, which a note may not
       carry, R9), the ancestor chain is find-or-created once per folder of
       the page, and `folder_ref_id` is set by id, compare-and-set on the
       folder nonce. The statement lists only `folder_ref_id`, so it fires
       none of the notes triggers but `folder_ref_live_only`, and `seq` and
       `updated_at` stay put: no sync feed or cache sees a change. Unresolved
       notes are drift (0 in steady state), so a decrypt per note is cheap.
    3. Attachments have no folder hash: each live attachment whose reference
       is not current (`folder_ref_stamp` differs from `path_nonce`, the
       `attachments_folder_ref_stale` index) has its path decrypted once (a
       page at a time), its folder find-or-created, and `folder_ref_id` set by
       id with the stamp of the nonce it was decrypted under
       (`Rows.attachment_ref/2`), compare-and-set on that nonce. Version 2
       stamps every row written before the stamp existed.

  Version 3 heals the references that name a soft-deleted folder row, left
  by rows written before the `folders_release_refs` trigger (20261106100000)
  released them (#2466 review, H1 and H2): a note's is re-pointed by step 2
  (its selection takes a dead reference), an attachment's is released first
  (reference and stamp NULL, `release_dead_attachment_refs/1`) so step 3
  re-resolves it, and a live marker whose row died gets one back from step 1.

  A row a writer holds is skipped (`FOR UPDATE SKIP LOCKED`), never waited
  on; the pass reports `:more` until a look finds nothing left. A
  folder or path that does not decrypt keeps the ledger open too (a closed
  ledger must not hide an unfixed row).

  Names are encrypted under the vault owner's per-user DEK, AAD
  `Crypto.aad_for_row(:folders, :name, id)`: the key scheme `folder_ciphertext`
  already uses. Root notes keep a NULL `folder_ref_id` (the root has no row).

  Known edges, none blocking: an emptied derived folder row is not pruned
  here (writers own that); a marker created after a derived row of the same
  name exists makes that row `explicit` and keeps ITS id.

  Readers trust an attachment's `folder_ref_id` only while its stamp matches
  (`Rows.attachment_ref_current/0`); a note's is kept by the
  `notes_set_folder_ref` trigger.
  """
  @behaviour Engram.DataMigration

  alias Engram.Accounts.User
  alias Engram.Attachments.BulkUpdate
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Crypto.RotationInProgressError
  alias Engram.DataMigrations
  alias Engram.Folders.Folder
  alias Engram.Folders.Rows
  alias Engram.Logger.Metadata
  alias Engram.Notes.Helpers
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @batch 1_000
  # Wall-clock budget for one user's attachment walk. The walk is keyset-paged
  # over the unstamped rows only, so this is far above the largest vault (34k
  # paths decrypt in seconds) and only bounds a pathological one.
  @attachment_budget_ms 20 * 60 * 1000

  # The stale page: `Engram.Folders.Drift.attachments_stale_sql/0`, the
  # predicate of `attachments_folder_ref_stale` (joined at compile time).
  @stale_attachment_page "SELECT id, vault_id, dek_version, path_ciphertext, path_nonce, " <>
                           "folder_ref_id FROM attachments " <>
                           "WHERE user_id = $1 AND ($2::uuid IS NULL OR id > $2) AND " <>
                           Engram.Folders.Drift.attachments_stale_sql() <>
                           " ORDER BY id LIMIT $3"

  @impl true
  def name, do: "folder_table"

  @impl true
  # 2: stamps `attachments.folder_ref_stamp` (20261103140000) on every row.
  # 3: heals references to soft-deleted folder rows (see the moduledoc).
  def version, do: 3

  @impl true
  def run_pass, do: run_pass([])

  @doc "True once every note and attachment has its folder resolved."
  @spec done?() :: boolean()
  def done?, do: DataMigrations.done?(name(), version())

  @doc false
  # `batch:` overrides the batch size (tests page over a few rows), `user_ids:`
  # restricts the pass to those users (tests prove the others are untouched).
  def run_pass(opts) do
    batch = Keyword.get(opts, :batch, @batch)
    budget = Keyword.get(opts, :attachment_budget_ms, @attachment_budget_ms)

    stats =
      Keyword.get_lazy(opts, :user_ids, &TenantScan.user_ids/0)
      |> Enum.map(&safe_migrate_user(&1, batch, budget))
      |> Enum.reduce(zero(), &add/2)

    if stats.changed + stats.blocked + stats.more == 0,
      do: :done,
      else: {:more, rows: stats.changed, blocked: stats.blocked}
  end

  # ---- per user ------------------------------------------------------------

  defp zero, do: %{changed: 0, blocked: 0, more: 0}
  defp add(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

  # One user raising (a unique violation, a decrypt crash, a transaction
  # timeout) must not stop the users after it, on every pass: it is logged and
  # counted as blocked, which keeps the ledger open. Its steps are separate
  # transactions, so what it already wrote stays and the next pass resumes.
  defp safe_migrate_user(user_id, batch, budget) do
    migrate_user(user_id, batch, budget)
  rescue
    # Deferred, not failed: the rotation ends in minutes and the next pass
    # (the ledger stays open through `blocked`) finds the user unlocked.
    RotationInProgressError ->
      %{zero() | blocked: 1}

    # Or a user under deletion (its vault rows are held, or it deadlocked with
    # the delete): likewise retried by the next pass, not an error.
    e ->
      if lock_conflict?(e), do: %{zero() | blocked: 1}, else: user_failed(user_id, e)
  catch
    :exit, reason -> user_failed(user_id, reason)
  end

  defp lock_conflict?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:lock_not_available, :deadlock_detected]

  defp lock_conflict?(_), do: false

  defp user_failed(user_id, reason) do
    Logger.error(
      "folder_table: user pass failed",
      Metadata.with_category(:error, :sync,
        user_id: user_id,
        reason: Metadata.safe_reason(reason)
      )
    )

    %{zero() | blocked: 1}
  end

  defp migrate_user(user_id, batch, budget) do
    # Read the key's version BEFORE the key itself (`RotationGate.check/2`).
    dek_version = RotationGate.dek_version(user_id)

    with %User{} = user <- Repo.get(User, user_id),
         {:ok, dek} <- Crypto.get_dek(user) do
      ctx = %{
        user_id: user_id,
        dek: dek,
        dek_version: dek_version,
        fk: Crypto.dek_filter_key_from_bytes(dek),
        batch: batch,
        deadline: System.monotonic_time(:millisecond) + budget
      }

      tree = scope(ctx, &load_tree(&1, ctx))

      {tree, markers} = markers(ctx, tree)
      {tree, notes} = notes(ctx, tree)
      released = %{zero() | changed: release_dead_attachment_refs(ctx)}
      {_tree, attachments} = attachments(ctx, tree)

      Enum.reduce([markers, notes, released, attachments], zero(), &add(&2, &1))
    else
      # No DEK, no encrypted rows.
      {:error, :no_dek} ->
        zero()

      nil ->
        zero()

      {:error, reason} ->
        Logger.error(
          "folder_table: no DEK for user",
          Metadata.with_category(:error, :sync,
            user_id: user_id,
            reason: Metadata.safe_reason(reason)
          )
        )

        %{zero() | blocked: 1}
    end
  end

  # One short transaction per step: a tenant block on SaaS' app pool, the
  # maintenance repo (its `maintenance_all` policies) where one is configured.
  # Every statement also filters on `user_id`.
  defp scope(ctx, fun) do
    case Repo.maintenance() do
      Repo ->
        Repo.with_tenant!(ctx.user_id, fn -> gated(Repo, ctx, fun) end)

      maintenance ->
        {:ok, result} = maintenance.transaction(fn -> gated(maintenance, ctx, fun) end)
        result
    end
  end

  # A DEK rotation re-keys `folders` once, then flips the key: a folder written
  # under the old key after that sweep would never be re-keyed. So every
  # transaction first takes the user's rotation lock FOR SHARE (a rotation
  # starting meanwhile waits for it) and refuses a locked user or a key that
  # moved since `ctx.dek` was read. The maintenance pool's tenant block does
  # not gate by itself.
  #
  # The vault rows come FIRST, NOWAIT: `delete_account` deletes vaults, then the
  # user row, and this transaction's user-row lock followed by the folders FK's
  # vault-row lock is the opposite order, a deadlock Postgres broke by killing
  # the delete (#2339). A vault held by a delete defers the user instead.
  defp gated(repo, ctx, fun) do
    :ok = Vaults.lock_user_vaults_nowait!(repo, ctx.user_id)
    # A folder rename or batch move in flight holds its vault's folder-write
    # lock across its scan and writes: skip the user (blocked, retried).
    :ok = Vaults.try_folder_write_locks!(repo, ctx.user_id)

    case RotationGate.check(ctx.user_id,
           repo: repo,
           share_lock: true,
           dek_version: ctx.dek_version
         ) do
      :ok -> fun.(repo)
      {:error, :user_not_found} -> fun.(repo)
      {:error, :rotation_in_progress} -> raise Engram.Crypto.RotationInProgressError
    end
  end

  # ---- the in-memory folder tree -------------------------------------------

  # `by_key`: {vault, parent, name_hmac} -> %{id, full} for live folders;
  # `by_id`: id -> key. All ids are raw 16-byte binaries, as Postgrex returns them.
  defp load_tree(repo, ctx) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT id, vault_id, parent_id, name_hmac, full_path_hmac FROM folders
        WHERE user_id = $1 AND deleted_at IS NULL
        """,
        [dump(ctx.user_id)]
      )

    Enum.reduce(rows, %{by_key: %{}, by_id: %{}}, fn [id, vault, parent, name, full], tree ->
      put(tree, {vault, parent, name}, id, full)
    end)
  end

  defp put(tree, key, id, full) do
    %{
      tree
      | by_key: Map.put(tree.by_key, key, %{id: id, full: full}),
        by_id: Map.put(tree.by_id, id, key)
    }
  end

  # Find-or-create the chain for `path` ("A/B/C") in `vault`; returns the
  # leaf's folder id. `explicit` (a marker's UUID, if any) is only applied to
  # the leaf. Folds a stats map: every write counts as a change.
  defp ensure_path(repo, ctx, {tree, stats}, vault, path, leaf \\ nil) do
    segments = String.split(path, "/", trim: true)
    last = length(segments) - 1

    {_prefix, parent, state} =
      segments
      |> Enum.with_index()
      |> Enum.reduce({"", nil, {tree, stats}}, fn {segment, i}, {prefix, parent, state} ->
        full_path = if prefix == "", do: segment, else: prefix <> "/" <> segment
        opts = if i == last, do: leaf, else: nil
        {id, state} = ensure_one(repo, ctx, state, vault, parent, segment, full_path, opts)
        {full_path, id, state}
      end)

    {parent, state}
  end

  # `leaf` is `%{id: marker_id}` for a marker's own folder, else nil.
  defp ensure_one(repo, ctx, {tree, stats}, vault, parent, segment, full_path, leaf) do
    name_hmac = Folder.name_hmac(ctx.fk, segment)
    full = Rows.path_hmac(ctx.fk, full_path)
    key = {vault, parent, name_hmac}
    explicit? = leaf != nil

    case tree.by_key[key] do
      nil ->
        id = if leaf, do: leaf.id, else: dump(Ecto.UUID.generate())
        existing? = leaf != nil and Map.has_key?(tree.by_id, id)

        row = %{
          id: id,
          vault: vault,
          parent: parent,
          segment: segment,
          name_hmac: name_hmac,
          full: full
        }

        if existing? do
          # The marker's folder row exists at another place: an older release
          # renamed the marker. Move it here (the place is free).
          update_row(repo, ctx, row, true)
          tree = %{tree | by_key: Map.delete(tree.by_key, tree.by_id[id])}
          {id, {put(tree, key, id, full), bump(stats)}}
        else
          case insert_row(repo, ctx, row, explicit?) do
            1 ->
              {id, {put(tree, key, id, full), bump(stats)}}

            # A writer made the same folder after the tree was read, or the
            # marker's UUID names a tombstoned row: read the winner, or revive
            # that row here, instead of failing the user's whole pass.
            0 ->
              case live_row(repo, vault, parent, name_hmac) do
                [found, found_full] ->
                  tree = put(tree, key, found, found_full)
                  ensure_one(repo, ctx, {tree, stats}, vault, parent, segment, full_path, leaf)

                nil ->
                  update_row(repo, ctx, row, true)
                  {id, {put(tree, key, id, full), bump(stats)}}
              end
          end
        end

      %{id: id, full: ^full} when not explicit? ->
        {id, {tree, stats}}

      %{id: id} ->
        # Present: set what the marker or the trigger lookup needs. Counts as
        # a change only if a row really moved (the daily pass must find none).
        %{num_rows: n} =
          repo.query!(
            "UPDATE folders SET full_path_hmac = $2, explicit = explicit OR $3, updated_at = now() " <>
              "WHERE id = $1 AND (full_path_hmac IS DISTINCT FROM $2 OR ($3 AND NOT explicit))",
            [id, full, explicit?]
          )

        if n > 0,
          do: {id, {put(tree, key, id, full), bump(stats)}},
          else: {id, {tree, stats}}
    end
  end

  defp live_row(repo, vault, parent, name_hmac) do
    case repo.query!(
           """
           SELECT id, full_path_hmac FROM folders
           WHERE vault_id = $1 AND name_hmac = $2 AND deleted_at IS NULL
             AND parent_id IS NOT DISTINCT FROM $3::uuid
           """,
           [vault, name_hmac, parent]
         ) do
      %{rows: [row | _]} -> row
      _ -> nil
    end
  end

  # Rows inserted (0 when a live folder of that name, or that id, exists).
  defp insert_row(repo, ctx, row, explicit?) do
    {ct, nonce} = encrypt_name(ctx, row.id, row.segment)

    %{num_rows: n} =
      repo.query!(
        """
        INSERT INTO folders (id, vault_id, user_id, parent_id, name_ciphertext, name_nonce,
                             name_hmac, full_path_hmac, dek_version, explicit)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ON CONFLICT DO NOTHING
        """,
        [
          row.id,
          row.vault,
          dump(ctx.user_id),
          row.parent,
          ct,
          nonce,
          row.name_hmac,
          row.full,
          Crypto.row_version_aad_bound(),
          explicit?
        ]
      )

    n
  end

  defp update_row(repo, ctx, row, explicit?) do
    {ct, nonce} = encrypt_name(ctx, row.id, row.segment)

    repo.query!(
      """
      UPDATE folders SET parent_id = $2, name_ciphertext = $3, name_nonce = $4, name_hmac = $5,
             full_path_hmac = $6, dek_version = $7, explicit = explicit OR $8, updated_at = now(),
             deleted_at = NULL, delete_op_id = NULL
      WHERE id = $1 AND vault_id = $9 AND user_id = $10
      """,
      [
        row.id,
        row.parent,
        ct,
        nonce,
        row.name_hmac,
        row.full,
        Crypto.row_version_aad_bound(),
        explicit?,
        row.vault,
        dump(ctx.user_id)
      ]
    )
  end

  defp encrypt_name(ctx, id, segment),
    do: Rows.encrypt_name(ctx.dek, Ecto.UUID.load!(id), segment)

  defp bump(stats), do: %{stats | changed: stats.changed + 1}

  # ---- 1. markers ----------------------------------------------------------

  defp markers(ctx, tree) do
    %{rows: rows} =
      scope(ctx, fn repo ->
        repo.query!(
          """
          SELECT id, vault_id, dek_version, folder_ciphertext, folder_nonce FROM notes
          WHERE user_id = $1 AND kind = 'folder' AND deleted_at IS NULL ORDER BY id
          """,
          [dump(ctx.user_id)]
        )
      end)

    {_, state} =
      in_chunks(ctx, rows, {tree, zero()}, fn repo, [id, vault, dv, ct, nonce], {tree, stats} ->
        case decrypt_folder(ctx, id, dv, ct, nonce) do
          {:ok, ""} ->
            {[], {tree, stats}}

          {:ok, path} ->
            {_leaf, state} = ensure_path(repo, ctx, {tree, stats}, vault, path, %{id: id})
            {[], state}

          :error ->
            {[], {tree, blocked(stats, "marker", id)}}
        end
      end)

    state
  end

  # `fun.(repo, item, state)` returns `{outputs, state}`. Items run `batch` to
  # a transaction, so a user with tens of thousands of folders stays under the
  # transaction timeout; `ensure_path` is idempotent, so a failed chunk is
  # simply done again by the next pass.
  defp in_chunks(ctx, items, state, fun) do
    items
    |> Enum.chunk_every(ctx.batch)
    |> Enum.flat_map_reduce(state, fn chunk, state ->
      scope(ctx, fn repo ->
        Enum.flat_map_reduce(chunk, state, &fun.(repo, &1, &2))
      end)
    end)
  end

  # ---- 2. notes ------------------------------------------------------------

  # The live notes in a non-root folder whose reference is missing or names a
  # dead row, a page of `batch` at a time by id. Each one's own folder envelope
  # is decrypted: never `notes.folder_hmac`, which a note may not carry (R9).
  # The root (an empty envelope, the 16-byte tag) has no row and is never
  # selected. The NULL arm is `notes_unresolved_folder`'s drift; the dead arm
  # the version 3 heal.
  @unresolved_note_page """
  SELECT n.id, n.vault_id, n.dek_version, n.folder_ciphertext, n.folder_nonce
  FROM notes n
  WHERE n.user_id = $1 AND ($2::uuid IS NULL OR n.id > $2)
    AND n.kind = 'note' AND n.deleted_at IS NULL AND octet_length(n.folder_ciphertext) > 16
    AND (n.folder_ref_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM folders f WHERE f.id = n.folder_ref_id AND f.deleted_at IS NULL))
  ORDER BY n.id LIMIT $3
  """

  defp notes(ctx, tree, after_id \\ nil, stats \\ zero()) do
    %{rows: rows} =
      scope(ctx, & &1.query!(@unresolved_note_page, [dump(ctx.user_id), after_id, ctx.batch]))

    {found, stats} =
      Enum.reduce(rows, {[], stats}, fn [id, vault, dv, ct, nonce], {acc, stats} ->
        case decrypt_folder(ctx, id, dv, ct, nonce) do
          {:ok, ""} -> {acc, stats}
          {:ok, path} -> {[{id, nonce, vault, path} | acc], stats}
          :error -> {acc, blocked(stats, "note folder", id)}
        end
      end)

    # One find-or-create per distinct folder of the page.
    {leaves, {tree, stats}} =
      in_chunks(
        ctx,
        found |> Enum.map(&{elem(&1, 2), elem(&1, 3)}) |> Enum.uniq(),
        {tree, stats},
        fn repo, {vault, path}, state ->
          {leaf, state} = ensure_path(repo, ctx, state, vault, path)
          {[{{vault, path}, leaf}], state}
        end
      )

    leaf_of = Map.new(leaves)
    points = for {id, nonce, vault, path} <- found, do: {id, nonce, leaf_of[{vault, path}]}
    updated = point_notes(ctx, points)

    # A note a writer held (skipped) or moved since the read (its nonce
    # changed) keeps the ledger open; the next pass looks again.
    stats = %{stats | changed: stats.changed + updated}
    stats = if updated < length(points), do: %{stats | blocked: stats.blocked + 1}, else: stats

    if length(rows) == ctx.batch,
      do: notes(ctx, tree, rows |> List.last() |> hd(), stats),
      else: {tree, stats}
  end

  # `UPDATE notes SET folder_ref_id = leaf` by id, compare-and-set on the
  # folder nonce the envelope was decrypted under, locked rows skipped. Lists
  # only `folder_ref_id`: no sync feed or cache sees a change. Cost: one
  # primary-key probe per note.
  defp point_notes(_ctx, []), do: 0

  defp point_notes(ctx, points) do
    {ids, nonces, leaves} =
      Enum.reduce(points, {[], [], []}, fn {id, nonce, leaf}, {i, n, l} ->
        {[id | i], [nonce | n], [leaf | l]}
      end)

    scope(ctx, fn repo ->
      %{num_rows: count} =
        repo.query!(
          """
          UPDATE notes n SET folder_ref_id = l.leaf
          FROM unnest($2::uuid[], $3::bytea[], $4::uuid[]) AS l(id, nonce, leaf)
          WHERE n.id = l.id AND n.folder_nonce = l.nonce
            AND n.id = ANY(ARRAY(
              SELECT id FROM notes
              WHERE user_id = $1 AND id = ANY($2) AND kind = 'note' AND deleted_at IS NULL
              ORDER BY id FOR UPDATE SKIP LOCKED))
          """,
          [dump(ctx.user_id), ids, nonces, leaves]
        )

      count
    end)
  end

  # ---- 3. attachments ------------------------------------------------------

  # A live attachment whose reference names a soft-deleted row, with a stamp
  # that is still current (so the walk below would not look at it): reference
  # and stamp NULL, as `folders_release_refs` does for a delete today, `batch`
  # rows at a time, locked rows skipped (the next pass takes them). Cost: one
  # walk of the user's folder rows (`folders_user`), each dead one probing
  # `attachments_folder_ref`; empty once healed. Dead folder rows are never
  # purged, so this walk grows with them (small: one row per deleted folder);
  # it runs on drain-triggered passes too. Returns the rows released.
  defp release_dead_attachment_refs(ctx, n \\ 0) do
    count =
      scope(ctx, fn repo ->
        %{num_rows: count} =
          repo.query!(
            """
            UPDATE attachments SET folder_ref_id = NULL, folder_ref_stamp = NULL
            WHERE id = ANY(ARRAY(
              SELECT a.id FROM folders f
              JOIN attachments a ON a.vault_id = f.vault_id AND a.folder_ref_id = f.id
              WHERE f.user_id = $1 AND f.deleted_at IS NOT NULL AND a.deleted_at IS NULL
              ORDER BY a.id LIMIT $2 FOR UPDATE OF a SKIP LOCKED))
            """,
            [dump(ctx.user_id), ctx.batch]
          )

        count
      end)

    if count < ctx.batch, do: n + count, else: release_dead_attachment_refs(ctx, n + count)
  end

  defp attachments(ctx, tree, after_id \\ nil, stats \\ zero())

  # Out of time: not a failure, the next pass walks again (`more`, not `blocked`).
  defp attachments(%{deadline: deadline} = ctx, tree, after_id, stats) when after_id != nil do
    if System.monotonic_time(:millisecond) > deadline,
      do: {tree, %{stats | more: stats.more + 1}},
      else: attachment_page(ctx, tree, after_id, stats)
  end

  defp attachments(ctx, tree, after_id, stats), do: attachment_page(ctx, tree, after_id, stats)

  defp attachment_page(ctx, tree, after_id, stats) do
    {tree, stats, last, size} =
      scope(ctx, fn repo ->
        %{rows: rows} =
          repo.query!(
            @stale_attachment_page,
            [dump(ctx.user_id), after_id, ctx.batch]
          )

        {tree, stats, wanted} =
          Enum.reduce(rows, {tree, stats, []}, fn [id, vault, dv, ct, nonce, current],
                                                  {tree, stats, wanted} ->
            case decrypt_path(ctx, id, dv, ct, nonce) do
              {:ok, path} ->
                {leaf, {tree, stats}} =
                  case Helpers.extract_folder(path) do
                    "" -> {nil, {tree, stats}}
                    folder -> ensure_path(repo, ctx, {tree, stats}, vault, folder)
                  end

                # Unstamped: written even when the reference is right, to stamp it.
                {tree, stats, [{id, leaf, nonce, nonce} | wanted]}

              # Logged once, then marked unreadable at this nonce: out of the
              # drain's index until a writer rewrites the path (a fresh nonce),
              # and never trusted by readers (the stamp is not the nonce).
              :error ->
                stamp = Rows.unreadable_attachment_stamp(nonce)

                {tree, blocked(stats, "attachment path", id),
                 [{id, current, nonce, stamp} | wanted]}
            end
          end)

        updated = BulkUpdate.point_attachments(repo, wanted)
        skipped = length(wanted) - updated
        stats = %{stats | changed: stats.changed + updated, blocked: stats.blocked + skipped}
        {tree, stats, rows |> List.last() |> then(&(&1 && hd(&1))), length(rows)}
      end)

    if size < ctx.batch,
      do: {tree, stats},
      else: attachments(ctx, tree, last, stats)
  end

  # ---- decrypt -------------------------------------------------------------

  defp decrypt_folder(ctx, id, dv, ct, nonce),
    do: Rows.decrypt_field(ctx.dek, :notes, :folder, id, dv, ct, nonce)

  defp decrypt_path(ctx, id, dv, ct, nonce),
    do: Rows.decrypt_field(ctx.dek, :attachments, :path, id, dv, ct, nonce)

  defp blocked(stats, what, id) do
    Logger.warning(
      "folder_table: #{what} did not decrypt",
      Metadata.with_category(:warning, :sync, row_id: Ecto.UUID.load!(id))
    )

    %{stats | blocked: stats.blocked + 1}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
end
