defmodule Engram.Links do
  @moduledoc """
  Persistence + resolution for wikilink/embed edges (issue #591).

  Consumes `Engram.Links.Parser.extract/1` output and turns it into
  `note_links` rows: each target is resolved to a note/attachment id (or
  left dangling) via an HMAC-indexed basename lookup, since Obsidian link
  resolution is case-insensitive and path-agnostic when the link omits a
  folder.

  Every query here runs with `skip_tenant_check: true` — callers are trusted
  internal pipelines (note write path, backfill workers), not
  request-scoped user input, so this module carries its own filters rather
  than relying on `Repo.with_tenant/2` RLS. The actual invariant, by
  function class:

    * Row-id-scoped mutations (`replace_links/4`'s delete, `rebind_edge/4`'s
      update) carry `user_id` (+ `vault_id` where it's in scope) alongside
      the row id — belt-and-suspenders against a wrong/stale id, not the
      only thing narrowing the query.
    * Mutations driven by a list of ids (`on_note_soft_deleted/2`,
      `on_attachment_soft_deleted/2` and its batched sibling) carry only
      `user_id`: `vault_id` isn't in scope at those call sites, but the ids
      themselves originate from tenant-scoped queries upstream (e.g.
      `Notes.delete_note/4`, `Attachments.batch_delete/3`), so cross-tenant
      rows can't reach them.
    * Reads (`links_for_note/2`, `backlinks_for_note/2`) filter `user_id`
      only, for the same reason — the note id passed in was already
      resolved through a tenant-scoped lookup by the caller.
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Links.NoteLink
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes.Note
  alias Engram.Repo

  @note_exts ~w(.md .canvas)
  @backlinks_limit 200

  @doc """
  Lowercased basename with `.md`/`.canvas` stripped (other extensions kept).
  Obsidian link resolution is case-insensitive and matches on basename
  alone unless the link includes a folder path.
  """
  @spec basename_key(String.t()) :: String.t()
  def basename_key(path_or_target) do
    base = path_or_target |> String.split("/") |> List.last() |> String.downcase()
    ext = Path.extname(base)
    if ext in @note_exts, do: String.replace_suffix(base, ext, ""), else: base
  end

  @doc """
  Deletes all outgoing edges for `source_note_id` and inserts fresh ones
  from `parsed` (as produced by `Engram.Links.Parser.extract/1`), resolving
  each target. Idempotent — safe to call on every note write.
  """
  @spec replace_links(map(), map(), binary(), [map()]) :: :ok
  def replace_links(user, vault, source_note_id, parsed) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    now = DateTime.utc_now()

    rows =
      Enum.map(parsed, fn p ->
        id = Engram.Notes.mint_id()

        {tct, tnonce} =
          Envelope.encrypt(p.target, dek, Crypto.aad_for_row(:note_links, :target_text, id))

        {target_note_id, target_attachment_id} =
          case resolve_target(user, vault, p.target, p.link_type) do
            {:note, nid} -> {nid, nil}
            {:attachment, aid} -> {nil, aid}
            :dangling -> {nil, nil}
          end

        %{
          id: id,
          user_id: user.id,
          vault_id: vault.id,
          source_note_id: source_note_id,
          target_note_id: target_note_id,
          target_attachment_id: target_attachment_id,
          target_text_ciphertext: tct,
          target_text_nonce: tnonce,
          target_basename_hmac: Crypto.hmac_field(filter_key, basename_key(p.target)),
          link_type: p.link_type,
          position: p.position,
          dek_version: Crypto.row_version_aad_bound(),
          inserted_at: now
        }
        |> put_optional_envelope(:alias, p.alias, dek, id)
        |> put_optional_envelope(:anchor, p.anchor, dek, id)
      end)

    Repo.transaction(fn ->
      Repo.delete_all(
        from(l in NoteLink,
          where:
            l.source_note_id == ^source_note_id and l.user_id == ^user.id and
              l.vault_id == ^vault.id
        ),
        skip_tenant_check: true
      )

      if rows != [], do: Repo.insert_all(NoteLink, rows, skip_tenant_check: true)
    end)

    :ok
  end

  defp put_optional_envelope(row, field, nil, _dek, _id) do
    {ct_key, nonce_key} = envelope_keys(field)
    row |> Map.put(ct_key, nil) |> Map.put(nonce_key, nil)
  end

  defp put_optional_envelope(row, field, value, dek, id) do
    {ct_key, nonce_key} = envelope_keys(field)
    {ct, nonce} = Envelope.encrypt(value, dek, Crypto.aad_for_row(:note_links, field, id))
    row |> Map.put(ct_key, ct) |> Map.put(nonce_key, nonce)
  end

  defp envelope_keys(:alias), do: {:alias_ciphertext, :alias_nonce}
  defp envelope_keys(:anchor), do: {:anchor_ciphertext, :anchor_nonce}

  @doc """
  Resolves a raw link target to a note, an attachment, or `:dangling`.

  Extension decides which table to try FIRST: extensionless targets and
  `.md`/`.canvas` targets try notes first; any other extension tries
  attachments first — for both wikilinks and embeds (`link_type` does not
  gate this; `[[image.png]]` links to the attachment same as
  `![[image.png]]` does in Obsidian). A target can still have a real
  extension and be a note (`[[Node.js]]`, `[[Meeting 2026.08]]` — a bare
  wikilink target's "extension" is just whatever follows the last dot in
  its basename, and `Path.extname/1` doesn't know note titles from file
  extensions): when the extension-preferred table comes back dangling, the
  OTHER table is tried with the same hmac before giving up. Notes are the
  preferred table for the common case (extensionless/`.md`/`.canvas`
  targets), so this only ever falls back to attachments for those, and
  falls back to notes for everything else — it does not re-check the
  first table once it has a hit. Candidates are filtered to live rows
  (`deleted_at IS NULL`) matching the target's basename HMAC; a target
  containing `/` is further narrowed to candidates whose decrypted full
  path matches case-insensitively (trying the target as given and with
  `.md`/`.canvas` appended). Among the survivors, the shortest path wins;
  ties break lexicographically.
  """
  @spec resolve_target(map(), map(), String.t(), String.t()) ::
          {:note, binary()} | {:attachment, binary()} | :dangling
  def resolve_target(user, vault, target, _link_type) do
    key = basename_key(target)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    hmac = Crypto.hmac_field(filter_key, key)
    ext = target |> Path.basename() |> Path.extname() |> String.downcase()

    route_resolution(
      ext,
      fn -> resolve_note_target(user, vault, target, hmac) end,
      fn -> resolve_attachment_target(user, vault, target, hmac) end
    )
  end

  # Extension-preference + cross-table-fallback rule, shared by the
  # single-shot `resolve_target/4` path and the batch `rebind_edge/6` path
  # (#591 finding — was forked into two copies of this same if/else before).
  # `note_resolver`/`attachment_resolver` are zero-arg thunks so the
  # single-shot caller keeps its lazy short-circuit (never queries the
  # second table unless the first came back dangling) while the batch
  # caller can pass thunks that just return already-fetched candidates.
  defp route_resolution(ext, note_resolver, attachment_resolver) do
    if ext != "" and ext not in @note_exts do
      with :dangling <- attachment_resolver.() do
        note_resolver.()
      end
    else
      with :dangling <- note_resolver.() do
        attachment_resolver.()
      end
    end
  end

  defp resolve_note_target(user, vault, target, hmac) do
    fetch_decrypted_candidates(user, vault, hmac, :notes)
    |> resolve_from_candidates(target, :note)
  end

  defp resolve_attachment_target(user, vault, target, hmac) do
    fetch_decrypted_candidates(user, vault, hmac, :attachments)
    |> resolve_from_candidates(target, :attachment)
  end

  # Query + decrypt only (no target-dependent filtering) — the part that's
  # IDENTICAL for every edge sharing an hmac, so `bind_danglers_for_hmac/3`
  # can call this once per table instead of once per edge.
  defp fetch_decrypted_candidates(user, vault, hmac, :notes) do
    from(n in Note,
      where:
        n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
          n.basename_hmac == ^hmac and is_nil(n.deleted_at),
      select: %{
        id: n.id,
        path_ciphertext: n.path_ciphertext,
        path_nonce: n.path_nonce,
        dek_version: n.dek_version
      }
    )
    |> Repo.all(skip_tenant_check: true)
    |> decrypt_candidate_paths(user, :notes)
  end

  defp fetch_decrypted_candidates(user, vault, hmac, :attachments) do
    from(a in Attachment,
      where:
        a.user_id == ^user.id and a.vault_id == ^vault.id and
          a.basename_hmac == ^hmac and is_nil(a.deleted_at),
      select: %{
        id: a.id,
        path_ciphertext: a.path_ciphertext,
        path_nonce: a.path_nonce,
        dek_version: a.dek_version
      }
    )
    |> Repo.all(skip_tenant_check: true)
    |> decrypt_candidate_paths(user, :attachments)
  end

  defp decrypt_candidate_paths([], _user, _table), do: []

  defp decrypt_candidate_paths(rows, user, table) do
    {:ok, dek} = Crypto.get_dek(user)

    rows
    |> Enum.map(fn row ->
      path =
        decrypt_field(
          row.path_ciphertext,
          row.path_nonce,
          dek,
          row.dek_version,
          table,
          :path,
          row.id
        )

      {row.id, path}
    end)
    |> Enum.reject(fn {_id, path} -> is_nil(path) end)
  end

  # Target-dependent filter + tiebreak — the part that varies per edge even
  # when the candidate set (fetched above) is shared.
  defp resolve_from_candidates(candidates, target, tag) do
    candidates
    |> filter_by_path(target)
    |> Enum.sort_by(fn {_id, path} -> {String.length(path), path} end)
    |> case do
      [] -> :dangling
      [{id, _path} | _] -> {tag, id}
    end
  end

  # A target with a folder segment narrows candidates to a full-path match
  # (case-insensitive); a bare basename target keeps every same-basename
  # candidate so the shortest-path tiebreak below can pick a winner.
  defp filter_by_path(candidates, target) do
    if String.contains?(target, "/") do
      variants =
        [target | Enum.map(@note_exts, &(target <> &1))]
        |> Enum.map(&String.downcase/1)

      Enum.filter(candidates, fn {_id, path} ->
        is_binary(path) and String.downcase(path) in variants
      end)
    else
      candidates
    end
  end

  @doc """
  Live (non-deleted) notes + attachments in `vault` whose `basename_hmac`
  matches `key` (a `basename_key/1` result). Drives the rename-rewrite form
  rule: a bare `[[basename]]` may stay bare only when the new basename is
  unambiguous (count == 1, the renamed row itself).
  """
  @spec live_basename_count(map(), map(), String.t()) :: non_neg_integer()
  def live_basename_count(user, vault, key) do
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    hmac = Crypto.hmac_field(filter_key, key)

    notes =
      Repo.one(
        from(n in Note,
          where:
            n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
              n.basename_hmac == ^hmac and is_nil(n.deleted_at),
          select: count(n.id)
        ),
        skip_tenant_check: true
      )

    attachments =
      Repo.one(
        from(a in Attachment,
          where:
            a.user_id == ^user.id and a.vault_id == ^vault.id and
              a.basename_hmac == ^hmac and is_nil(a.deleted_at),
          select: count(a.id)
        ),
        skip_tenant_check: true
      )

    notes + attachments
  end

  @doc """
  Would `target` have resolved to the renamed row (`renamed_id`) at its OLD
  path, under `resolve_target/4`'s rules? Reconstructs the pre-rename
  candidate set: current live candidates for the target's basename hmac,
  minus the renamed row's post-rename position, plus a synthetic candidate
  `{renamed_id, old_path}`. Order-independent w.r.t. the RebindNoteLinks
  jobs a rename enqueues — those rewrite edge target ids but never the
  candidate tables this consults.
  """
  @spec pre_rename_winner?(map(), map(), String.t(), :note | :attachment, binary(), String.t()) ::
          boolean()
  def pre_rename_winner?(user, vault, target, kind, renamed_id, old_path) do
    key = basename_key(target)

    if key != basename_key(old_path) do
      false
    else
      {:ok, filter_key} = Crypto.dek_filter_key(user)
      hmac = Crypto.hmac_field(filter_key, key)

      notes =
        user
        |> fetch_decrypted_candidates(vault, hmac, :notes)
        |> Enum.reject(fn {id, _path} -> id == renamed_id end)

      attachments =
        user
        |> fetch_decrypted_candidates(vault, hmac, :attachments)
        |> Enum.reject(fn {id, _path} -> id == renamed_id end)

      {notes, attachments} =
        case kind do
          :note -> {[{renamed_id, old_path} | notes], attachments}
          :attachment -> {notes, [{renamed_id, old_path} | attachments]}
        end

      ext = target |> Path.basename() |> Path.extname() |> String.downcase()

      case route_resolution(
             ext,
             fn -> resolve_from_candidates(notes, target, :note) end,
             fn -> resolve_from_candidates(attachments, target, :attachment) end
           ) do
        {:note, ^renamed_id} -> true
        {:attachment, ^renamed_id} -> true
        _ -> false
      end
    end
  end

  @doc """
  Computes the HMAC for a `basename_key/1` result under `user`'s filter key.
  Callers that need to enqueue a rebind job (`RebindNoteLinks.new_for/3`)
  compute this from plaintext they already have in scope, so the job's
  `oban_jobs.args` carries only the opaque HMAC — never the plaintext
  basename (T3.2/H3 invariant).
  """
  @spec basename_hmac(Engram.Accounts.User.t(), String.t()) :: binary()
  def basename_hmac(user, key) do
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    Crypto.hmac_field(filter_key, key)
  end

  @doc """
  Re-resolves every edge (dangling or currently bound) in the vault whose
  `target_basename_hmac` matches `hmac` (see `basename_hmac/2`). Called after
  a note or attachment is created/renamed/deleted so danglers can bind, and
  so an existing binding can be stolen by a shorter-path newcomer (see
  resolution rules on `resolve_target/4`).
  """
  @spec bind_danglers_for_hmac(map(), map(), binary()) :: :ok
  def bind_danglers_for_hmac(user, vault, hmac) do
    {:ok, dek} = Crypto.get_dek(user)

    edges =
      Repo.all(
        from(l in NoteLink,
          where:
            l.user_id == ^user.id and l.vault_id == ^vault.id and l.target_basename_hmac == ^hmac
        ),
        skip_tenant_check: true
      )

    if edges != [] do
      # Every edge here shares `hmac` (the WHERE clause above), so the
      # candidate query + decrypt below is IDENTICAL for all of them —
      # fetch once instead of once per edge (was N Repo.all + N decrypt
      # passes per table). Only the per-edge target text varies the
      # resolution (extension routing, path filter, tiebreak), which
      # `rebind_edge/6` applies in memory against these shared lists via
      # the same `route_resolution/3` + `resolve_from_candidates/3` rules
      # `resolve_target/4` uses.
      note_candidates = fetch_decrypted_candidates(user, vault, hmac, :notes)
      attachment_candidates = fetch_decrypted_candidates(user, vault, hmac, :attachments)

      Enum.each(edges, fn edge ->
        target_text =
          decrypt_field(
            edge.target_text_ciphertext,
            edge.target_text_nonce,
            dek,
            edge.dek_version,
            :note_links,
            :target_text,
            edge.id
          )

        # A decrypt failure (corrupt ciphertext, AAD-bind mismatch) yields
        # nil here — `rebind_edge/6` calls `Path.basename/1` on it, which
        # requires a binary and would crash the whole rebind job over one
        # bad row. Skip it (it stays exactly as-is, still eligible to
        # re-bind on a future pass) rather than let it take every other
        # edge down with it.
        if is_binary(target_text) do
          rebind_edge(user, vault, edge, target_text, note_candidates, attachment_candidates)
        else
          DecryptFailure.log(
            "bind_danglers_for_hmac: skipping undecryptable edge",
            :decrypt_failed,
            edge_id: edge.id
          )
        end
      end)
    end

    :ok
  end

  defp rebind_edge(user, vault, edge, target_text, note_candidates, attachment_candidates) do
    ext = target_text |> Path.basename() |> Path.extname() |> String.downcase()

    {target_note_id, target_attachment_id} =
      case route_resolution(
             ext,
             fn -> resolve_from_candidates(note_candidates, target_text, :note) end,
             fn -> resolve_from_candidates(attachment_candidates, target_text, :attachment) end
           ) do
        {:note, id} -> {id, nil}
        {:attachment, id} -> {nil, id}
        :dangling -> {nil, nil}
      end

    if {target_note_id, target_attachment_id} !=
         {edge.target_note_id, edge.target_attachment_id} do
      Repo.update_all(
        from(l in NoteLink,
          where: l.id == ^edge.id and l.user_id == ^user.id and l.vault_id == ^vault.id
        ),
        [set: [target_note_id: target_note_id, target_attachment_id: target_attachment_id]],
        skip_tenant_check: true
      )
    end
  end

  @doc """
  A note was soft-deleted: drop its outgoing edges (they're meaningless
  once the source is gone) and flip any incoming edges back to dangling
  (the target no longer exists, but the edge — and its encrypted target
  text — stays so it can re-bind if the note comes back).
  """
  @spec on_note_soft_deleted(binary(), binary()) :: :ok
  def on_note_soft_deleted(user_id, note_id) do
    Repo.delete_all(
      from(l in NoteLink, where: l.user_id == ^user_id and l.source_note_id == ^note_id),
      skip_tenant_check: true
    )

    Repo.update_all(
      from(l in NoteLink, where: l.user_id == ^user_id and l.target_note_id == ^note_id),
      [set: [target_note_id: nil]],
      skip_tenant_check: true
    )

    :ok
  end

  @doc """
  An attachment was soft-deleted: attachments carry no outgoing edges (only
  notes originate links, per `replace_links/4`), so there's nothing to drop
  there — only flip any incoming edges back to dangling (the target no
  longer exists, but the edge — and its encrypted target text — stays so it
  can re-bind if the attachment reappears at the same path, or a
  same-basename sibling can inherit it via the caller's paired
  `RebindNoteLinks` enqueue).
  """
  @spec on_attachment_soft_deleted(binary(), binary()) :: :ok
  def on_attachment_soft_deleted(user_id, attachment_id) do
    on_attachments_soft_deleted(user_id, [attachment_id])
  end

  @doc """
  Batched form of `on_attachment_soft_deleted/2` — same semantics (flip
  incoming edges to dangling, nothing to drop), one `UPDATE` for the whole
  list instead of one per attachment. Used by `Attachments.batch_delete/3`
  (#1194) to keep the N+1 the single-delete path can afford off the batch
  path.
  """
  @spec on_attachments_soft_deleted(binary(), [binary()]) :: :ok
  def on_attachments_soft_deleted(_user_id, []), do: :ok

  def on_attachments_soft_deleted(user_id, attachment_ids) when is_list(attachment_ids) do
    Repo.update_all(
      from(l in NoteLink,
        where: l.user_id == ^user_id and l.target_attachment_id in ^attachment_ids
      ),
      [set: [target_attachment_id: nil]],
      skip_tenant_check: true
    )

    :ok
  end

  @doc """
  Decrypted outgoing links for a note, in parser order.
  """
  @spec links_for_note(map(), binary()) :: [map()]
  def links_for_note(user, note_id) do
    user = reload_for_dek(user)
    {:ok, dek} = Crypto.get_dek(user)

    edges =
      Repo.all(
        from(l in NoteLink,
          where: l.user_id == ^user.id and l.source_note_id == ^note_id,
          order_by: l.position
        ),
        skip_tenant_check: true
      )

    target_paths =
      decrypt_note_paths(
        user,
        dek,
        edges |> Enum.map(& &1.target_note_id) |> Enum.reject(&is_nil/1)
      )

    Enum.map(edges, fn edge ->
      %{
        target_text:
          decrypt_field(
            edge.target_text_ciphertext,
            edge.target_text_nonce,
            dek,
            edge.dek_version,
            :note_links,
            :target_text,
            edge.id
          ),
        target_note_id: edge.target_note_id,
        target_attachment_id: edge.target_attachment_id,
        target_path: edge.target_note_id && Map.get(target_paths, edge.target_note_id),
        alias:
          decrypt_field(
            edge.alias_ciphertext,
            edge.alias_nonce,
            dek,
            edge.dek_version,
            :note_links,
            :alias,
            edge.id
          ),
        anchor:
          decrypt_field(
            edge.anchor_ciphertext,
            edge.anchor_nonce,
            dek,
            edge.dek_version,
            :note_links,
            :anchor,
            edge.id
          ),
        link_type: edge.link_type,
        dangling: is_nil(edge.target_note_id) and is_nil(edge.target_attachment_id)
      }
    end)
  end

  @doc """
  Max edges `backlinks_for_note/2` returns. Exposed so tests and callers
  (e.g. the OpenAPI schema description) can assert against the real value
  instead of hardcoding `200` a second place.
  """
  @spec backlinks_limit() :: pos_integer()
  def backlinks_limit, do: @backlinks_limit

  @doc """
  Decrypted incoming links (backlinks) for a note — one entry per edge
  pointing at it, carrying the source note's decrypted path/title.

  Capped at #{@backlinks_limit} edges (see `backlinks_limit/0`) — a
  heavily-linked note (e.g. a MOC/hub note) could otherwise return an
  unbounded response. Ordered by `position, id` so the cap is stable
  across calls; that same ordering is what a future keyset-paginated
  version of this function would page on.
  """
  @spec backlinks_for_note(map(), binary()) :: [map()]
  def backlinks_for_note(user, note_id) do
    user = reload_for_dek(user)
    {:ok, dek} = Crypto.get_dek(user)

    edges =
      Repo.all(
        from(l in NoteLink,
          where: l.user_id == ^user.id and l.target_note_id == ^note_id,
          order_by: [asc: l.position, asc: l.id],
          limit: ^@backlinks_limit
        ),
        skip_tenant_check: true
      )

    source_ids = edges |> Enum.map(& &1.source_note_id) |> Enum.uniq()

    sources =
      if source_ids == [] do
        %{}
      else
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.kind == "note" and n.id in ^source_ids,
            select: %{
              id: n.id,
              path_ciphertext: n.path_ciphertext,
              path_nonce: n.path_nonce,
              title_ciphertext: n.title_ciphertext,
              title_nonce: n.title_nonce,
              dek_version: n.dek_version
            }
          ),
          skip_tenant_check: true
        )
        |> Map.new(fn n ->
          {n.id,
           %{
             path:
               decrypt_field(
                 n.path_ciphertext,
                 n.path_nonce,
                 dek,
                 n.dek_version,
                 :notes,
                 :path,
                 n.id
               ),
             title:
               decrypt_field(
                 n.title_ciphertext,
                 n.title_nonce,
                 dek,
                 n.dek_version,
                 :notes,
                 :title,
                 n.id
               )
           }}
        end)
      end

    Enum.map(edges, fn edge ->
      source = Map.fetch!(sources, edge.source_note_id)

      %{
        source_note_id: edge.source_note_id,
        source_path: source.path,
        source_title: source.title,
        alias:
          decrypt_field(
            edge.alias_ciphertext,
            edge.alias_nonce,
            dek,
            edge.dek_version,
            :note_links,
            :alias,
            edge.id
          ),
        anchor:
          decrypt_field(
            edge.anchor_ciphertext,
            edge.anchor_nonce,
            dek,
            edge.dek_version,
            :note_links,
            :anchor,
            edge.id
          )
      }
    end)
  end

  # Read paths (called straight from controllers with `conn.assigns.current_user`)
  # can't trust that struct to carry a DEK: a same-request note write lazily
  # provisions the DEK via `Crypto.ensure_user_dek/1` deep inside `Notes`, but
  # that only updates the struct held *inside* that call — the controller's
  # `current_user` is resolved by auth middleware before the write and never
  # sees it. Same reload-fresh pattern `Indexing.index_note/2` uses (fetches by
  # `note.user_id` rather than trusting a passed-in user).
  defp reload_for_dek(%{id: id}), do: Engram.Accounts.get_user!(id)

  defp decrypt_note_paths(_user, _dek, []), do: %{}

  defp decrypt_note_paths(user, dek, note_ids) do
    Repo.all(
      from(n in Note,
        where: n.user_id == ^user.id and n.kind == "note" and n.id in ^note_ids,
        select: %{
          id: n.id,
          path_ciphertext: n.path_ciphertext,
          path_nonce: n.path_nonce,
          dek_version: n.dek_version
        }
      ),
      skip_tenant_check: true
    )
    |> Map.new(fn n ->
      {n.id,
       decrypt_field(n.path_ciphertext, n.path_nonce, dek, n.dek_version, :notes, :path, n.id)}
    end)
  end

  # Mirrors `Engram.Crypto`'s private dek_version dispatch (legacy rows =
  # empty AAD, AAD-bound rows reconstruct the bind string from row
  # identity). Kept local since that dispatch isn't part of Crypto's public
  # API, and we only ever need it for a single ciphertext+nonce pair here
  # rather than a whole-row decrypt.
  defp decrypt_field(nil, _nonce, _dek, _dek_version, _table, _column, _id), do: nil

  defp decrypt_field(ciphertext, nonce, dek, dek_version, table, column, id) do
    aad =
      if dek_version >= Crypto.row_version_aad_bound(),
        do: Crypto.aad_for_row(table, column, id),
        else: <<>>

    case Envelope.decrypt(ciphertext, nonce, dek, aad) do
      {:ok, plaintext} ->
        plaintext

      :error ->
        DecryptFailure.log("links_decrypt_failed", :decrypt_failed,
          table: table,
          column: column,
          row_id: id
        )

        nil
    end
  end
end
