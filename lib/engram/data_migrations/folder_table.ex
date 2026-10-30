defmodule Engram.DataMigrations.FolderTable do
  @moduledoc """
  Fills the `folders` table and `folder_ref_id` for rows written before the
  `notes_set_folder_ref` trigger and folder rows existed (migrations
  20261029000000..800). Every later note write resolves its own folder in
  the database, so this only catches up and heals what a previous-release
  writer left behind (re-verifies daily).

  Per user, through the maintenance pool where one is configured (SaaS) and
  per tenant otherwise, like `NoteSplit` (`TenantScan`):

    1. `kind = 'folder'` marker rows become `explicit` folders that KEEP the
       marker's UUID, so web and plugin ids stay stable.
    2. Notes: one envelope per DISTINCT `folder_hmac` is decrypted (the
       folder, never a note), split on `/`, and the ancestor chain is
       find-or-created. Then `UPDATE notes SET folder_ref_id = ? WHERE
       folder_hmac = ?` in batches of 1,000. The statement lists only
       `folder_ref_id`, so it fires none of the notes triggers
       (`notes_set_folder_ref` is `UPDATE OF folder_hmac`), and `seq` and
       `updated_at` stay put: no sync feed or cache sees a change.
    3. Attachments have no folder hash: each live attachment's path is
       decrypted once (a page at a time), its folder find-or-created and
       `folder_ref_id` set by id.

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

  Nothing reads the new column yet.
  """
  @behaviour Engram.DataMigration

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.RotationGate
  alias Engram.Crypto.RotationInProgressError
  alias Engram.Folders.Folder
  alias Engram.Logger.Metadata
  alias Engram.Notes.Helpers
  alias Engram.Repo

  require Logger

  @batch 1_000
  # Pages per user per pass: a pass is one bounded slice; the next run takes the rest.
  @max_batches 50

  @impl true
  def name, do: "folder_table"

  @impl true
  def version, do: 1

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass, do: run_pass([])

  @doc "True once every note and attachment has its folder resolved."
  @spec done?() :: boolean()
  def done?, do: Engram.DataMigrations.done?(name(), version())

  @doc false
  # `batch:` overrides the batch size (tests page over a few rows), `user_ids:`
  # restricts the pass to those users (tests prove the others are untouched).
  def run_pass(opts) do
    batch = Keyword.get(opts, :batch, @batch)

    stats =
      Keyword.get_lazy(opts, :user_ids, &TenantScan.user_ids/0)
      |> Enum.map(&safe_migrate_user(&1, batch))
      |> Enum.reduce(%{changed: 0, blocked: 0}, fn s, acc ->
        %{changed: acc.changed + s.changed, blocked: acc.blocked + s.blocked}
      end)

    if stats.changed + stats.blocked == 0,
      do: :done,
      else: {:more, rows: stats.changed, blocked: stats.blocked}
  end

  # ---- per user ------------------------------------------------------------

  # One user raising (a unique violation, a decrypt crash, a transaction
  # timeout) must not stop the users after it, on every pass: it is logged and
  # counted as blocked, which keeps the ledger open. Its steps are separate
  # transactions, so what it already wrote stays and the next pass resumes.
  defp safe_migrate_user(user_id, batch) do
    migrate_user(user_id, batch)
  rescue
    # Deferred, not failed: the rotation ends in minutes and the next pass
    # (the ledger stays open through `blocked`) finds the user unlocked.
    RotationInProgressError -> %{changed: 0, blocked: 1}
    e -> user_failed(user_id, e)
  catch
    :exit, reason -> user_failed(user_id, reason)
  end

  defp user_failed(user_id, reason) do
    Logger.error(
      "folder_table: user pass failed",
      Metadata.with_category(:error, :sync,
        user_id: user_id,
        reason: Metadata.safe_reason(reason)
      )
    )

    %{changed: 0, blocked: 1}
  end

  defp migrate_user(user_id, batch) do
    # Read the key's version BEFORE the key itself (`RotationGate.check/2`).
    dek_version = RotationGate.dek_version(user_id)

    with %User{} = user <- Repo.get(User, user_id),
         {:ok, dek} <- Crypto.get_dek(user) do
      ctx = %{
        user_id: user_id,
        dek: dek,
        dek_version: dek_version,
        fk: Crypto.dek_filter_key_from_bytes(dek),
        batch: batch
      }

      tree = scope(ctx, &load_tree(&1, ctx))

      {tree, markers} = markers(ctx, tree)
      {tree, notes} = notes(ctx, tree)
      {_tree, attachments} = attachments(ctx, tree)

      Enum.reduce([markers, notes, attachments], %{changed: 0, blocked: 0}, fn s, acc ->
        %{changed: acc.changed + s.changed, blocked: acc.blocked + s.blocked}
      end)
    else
      # No DEK, no encrypted rows.
      {:error, :no_dek} ->
        %{changed: 0, blocked: 0}

      nil ->
        %{changed: 0, blocked: 0}

      {:error, reason} ->
        Logger.error(
          "folder_table: no DEK for user",
          Metadata.with_category(:error, :sync,
            user_id: user_id,
            reason: Metadata.safe_reason(reason)
          )
        )

        %{changed: 0, blocked: 1}
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
  defp gated(repo, ctx, fun) do
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
    full = Crypto.hmac_field(ctx.fk, full_path)
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
          insert_row(repo, ctx, row, explicit?)
          {id, {put(tree, key, id, full), bump(stats)}}
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

  defp insert_row(repo, ctx, row, explicit?) do
    {ct, nonce} = encrypt_name(ctx, row.id, row.segment)

    repo.query!(
      """
      INSERT INTO folders (id, vault_id, user_id, parent_id, name_ciphertext, name_nonce,
                           name_hmac, full_path_hmac, dek_version, explicit)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
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
  end

  defp update_row(repo, ctx, row, explicit?) do
    {ct, nonce} = encrypt_name(ctx, row.id, row.segment)

    repo.query!(
      """
      UPDATE folders SET parent_id = $2, name_ciphertext = $3, name_nonce = $4, name_hmac = $5,
             full_path_hmac = $6, dek_version = $7, explicit = explicit OR $8, updated_at = now()
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
    do:
      Envelope.encrypt(segment, ctx.dek, Crypto.aad_for_row(:folders, :name, Ecto.UUID.load!(id)))

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
      in_chunks(ctx, rows, {tree, %{changed: 0, blocked: 0}}, fn repo,
                                                                 [id, vault, dv, ct, nonce],
                                                                 {tree, stats} ->
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

  # One look at the distinct folders that need work (no ref, or a ref to a
  # folder that is gone): one envelope each, never a note's.
  defp notes(ctx, tree) do
    %{rows: rows} =
      scope(ctx, fn repo ->
        repo.query!(
          """
          SELECT DISTINCT ON (n.vault_id, n.folder_hmac)
                 n.vault_id, n.folder_hmac, n.id, n.dek_version, n.folder_ciphertext, n.folder_nonce
          FROM notes n
          WHERE n.user_id = $1 AND n.kind = 'note' AND n.deleted_at IS NULL
            AND n.folder_hmac IS NOT NULL
            AND (n.folder_ref_id IS NULL OR NOT EXISTS (
                   SELECT 1 FROM folders f WHERE f.id = n.folder_ref_id AND f.deleted_at IS NULL))
          ORDER BY n.vault_id, n.folder_hmac, n.id
          """,
          [dump(ctx.user_id)]
        )
      end)

    stats = %{changed: 0, blocked: 0}

    {folders, stats} =
      Enum.reduce(rows, {[], stats}, fn [vault, hmac, id, dv, ct, nonce], {acc, stats} ->
        case decrypt_folder(ctx, id, dv, ct, nonce) do
          {:ok, ""} -> {acc, stats}
          {:ok, path} -> {[{vault, hmac, path} | acc], stats}
          :error -> {acc, blocked(stats, "note folder", id)}
        end
      end)

    {leaves, {tree, stats}} =
      in_chunks(ctx, folders, {tree, stats}, fn repo, {vault, hmac, path}, state ->
        {leaf, state} = ensure_path(repo, ctx, state, vault, path)
        {[{vault, hmac, leaf}], state}
      end)

    updated = Enum.reduce(leaves, 0, fn leaf, n -> n + point_notes(ctx, leaf) end)
    stats = %{stats | changed: stats.changed + updated}

    # A note a writer held was skipped; look once for any left.
    left? =
      leaves != [] and
        scope(ctx, fn repo ->
          %{rows: [[left?]]} =
            repo.query!(
              """
              SELECT EXISTS (SELECT 1 FROM notes WHERE user_id = $1 AND kind = 'note'
                AND deleted_at IS NULL AND folder_ref_id IS NULL AND folder_hmac = ANY($2))
              """,
              [dump(ctx.user_id), Enum.map(leaves, &elem(&1, 1))]
            )

          left?
        end)

    {tree, if(left?, do: %{stats | blocked: stats.blocked + 1}, else: stats)}
  end

  # `UPDATE notes SET folder_ref_id = ? WHERE folder_hmac = ?`, `batch` rows at
  # a time, locked rows skipped. `= ANY(ARRAY(...))` is an InitPlan, run once:
  # an IN subquery may be re-planned per row and, with SKIP LOCKED, drift.
  defp point_notes(ctx, {vault, hmac, leaf}, n \\ 0) do
    count =
      scope(ctx, fn repo ->
        %{num_rows: count} =
          repo.query!(
            """
            UPDATE notes SET folder_ref_id = $1
            WHERE id = ANY(ARRAY(
              SELECT id FROM notes
              WHERE user_id = $2 AND vault_id = $3 AND folder_hmac = $4 AND kind = 'note'
                AND deleted_at IS NULL AND folder_ref_id IS DISTINCT FROM $1
              ORDER BY id LIMIT $5 FOR UPDATE SKIP LOCKED))
            """,
            [leaf, dump(ctx.user_id), vault, hmac, ctx.batch]
          )

        count
      end)

    if count < ctx.batch, do: n + count, else: point_notes(ctx, {vault, hmac, leaf}, n + count)
  end

  # ---- 3. attachments ------------------------------------------------------

  defp attachments(ctx, tree, after_id \\ nil, stats \\ %{changed: 0, blocked: 0}, rounds \\ 0)

  defp attachments(_ctx, tree, _after, stats, @max_batches),
    do: {tree, %{stats | blocked: stats.blocked + 1}}

  defp attachments(ctx, tree, after_id, stats, rounds) do
    {tree, stats, last, size} =
      scope(ctx, fn repo ->
        %{rows: rows} =
          repo.query!(
            """
            SELECT id, vault_id, dek_version, path_ciphertext, path_nonce, folder_ref_id FROM attachments
            WHERE user_id = $1 AND deleted_at IS NULL AND ($2::uuid IS NULL OR id > $2)
            ORDER BY id LIMIT $3
            """,
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

                if leaf == current,
                  do: {tree, stats, wanted},
                  else: {tree, stats, [{id, leaf} | wanted]}

              :error ->
                {tree, blocked(stats, "attachment path", id), wanted}
            end
          end)

        updated = point_attachments(repo, wanted)
        skipped = length(wanted) - updated
        stats = %{stats | changed: stats.changed + updated, blocked: stats.blocked + skipped}
        {tree, stats, rows |> List.last() |> then(&(&1 && hd(&1))), length(rows)}
      end)

    if size < ctx.batch,
      do: {tree, stats},
      else: attachments(ctx, tree, last, stats, rounds + 1)
  end

  # By id, locked rows skipped. Returns the rows updated.
  defp point_attachments(_repo, []), do: 0

  defp point_attachments(repo, wanted) do
    {ids, leaves} = Enum.unzip(wanted)

    %{num_rows: count} =
      repo.query!(
        """
        WITH locked AS (SELECT id FROM attachments WHERE id = ANY($1::uuid[]) FOR UPDATE SKIP LOCKED)
        UPDATE attachments a SET folder_ref_id = v.fid
        FROM unnest($1::uuid[], $2::uuid[]) AS v(id, fid), locked l
        WHERE a.id = v.id AND l.id = a.id
        """,
        [ids, leaves]
      )

    count
  end

  # ---- decrypt -------------------------------------------------------------

  defp decrypt_folder(ctx, id, dv, ct, nonce),
    do: decrypt(ctx, :notes, :folder, id, dv, ct, nonce)

  defp decrypt_path(ctx, id, dv, ct, nonce),
    do: decrypt(ctx, :attachments, :path, id, dv, ct, nonce)

  defp decrypt(ctx, table, column, id, dv, ct, nonce) do
    aad =
      if Crypto.aad_bound?(dv),
        do: Crypto.aad_for_row(table, column, Ecto.UUID.load!(id)),
        else: <<>>

    case ct && Envelope.decrypt(ct, nonce, ctx.dek, aad) do
      {:ok, plaintext} -> {:ok, plaintext}
      _ -> :error
    end
  end

  defp blocked(stats, what, id) do
    Logger.warning(
      "folder_table: #{what} did not decrypt",
      Metadata.with_category(:warning, :sync, row_id: Ecto.UUID.load!(id))
    )

    %{stats | blocked: stats.blocked + 1}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
end
