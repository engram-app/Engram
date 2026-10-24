defmodule Engram.Links do
  @moduledoc """
  Persistence + resolution for wikilink/embed edges (issue #591).

  Consumes `Engram.Links.Parser.extract/1` output and turns it into
  `note_links` rows that keep each target's NAME (encrypted text plus HMAC
  keys). Reads resolve that name against the vault's live notes and
  attachments, the way Obsidian does: case-insensitive, and path-agnostic
  when the link omits a folder.

  ## Tenant scoping

  Every public function here opens `Repo.with_tenant/2`, because `note_links`
  (and the `notes`/`attachments` tables these reads join against) carry FORCE
  ROW LEVEL SECURITY. The in-query `user_id`/`vault_id` filters below are kept
  as belt-and-braces against a wrong or stale id — they are no longer the only
  thing narrowing a query.

  This module previously documented the opposite: that every query ran with
  `skip_tenant_check: true` because "callers are trusted internal pipelines",
  and that the hand-rolled filters were "the actual invariant". That reasoning
  does not survive contact with Postgres. `skip_tenant_check: true` suppresses
  only Engram's own guard in `Repo.prepare_query/3`; it sets no tenant, so
  under any role without SUPERUSER or BYPASSRLS the writes here raise 42501
  (`insert_all`) or silently match zero rows (`update_all`/`delete_all`), and
  the reads silently return nothing. A caller being trustworthy has no bearing
  on it.

  Nothing had ever failed because dev, CI and staging all connect as a
  superuser, which bypasses RLS even when FORCED — an accident of deployment,
  not a property of this code. The silent-read case was the more damaging half:
  `links_for_note/2` and `backlinks_for_note/2` would render a note with no
  edges at all, and `live_basename_count/3` returning 0 feeds rename-collision
  decisions.

  `with_tenant/2` is re-entrant for the same tenant, so the private helpers
  (`resolve_edges/4`, the candidate fetches) need no
  wrapping of their own, and a caller that already holds the tenant — e.g.
  `RewriteNoteLinks` — pays nothing.
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Links.NoteLink
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes.Keys
  alias Engram.Notes.Note
  alias Engram.Repo

  @typedoc "A candidate set indexed by `index_candidates/1`."
  @type candidate_index :: %{
          sorted: [{binary(), String.t()}],
          by_path: %{String.t() => {non_neg_integer(), binary()}}
        }

  @note_exts ~w(.md .canvas)

  # What the read paths need of an edge; the full row (17 columns, 5 uuids)
  # cost 28 us per edge to load against 7 for the decrypt.
  @edge_read_fields [
    :id,
    :vault_id,
    :source_note_id,
    :position,
    :link_type,
    :target_basename_hmac,
    :target_text_ciphertext,
    :target_text_nonce,
    :alias_ciphertext,
    :alias_nonce,
    :anchor_ciphertext,
    :anchor_nonce,
    :dek_version
  ]
  @backlink_read_fields [:link_keys_stamp, :target_key_hmac | @edge_read_fields]
  @backlinks_limit 200

  # Rows per `insert_all` statement. See replace_links/4: 17 binds per row
  # against the protocol's 65535 cap leaves room for 3855, so 2000 is a
  # deliberate half-margin — a new optional column must not silently re-arm
  # the overflow.
  @insert_chunk 2000

  # Unicode decides `String.length/1` (graphemes) and `String.downcase/1`,
  # so keys computed under another Unicode version are not trusted.
  @link_keys_version String.Unicode.version() |> Tuple.to_list() |> Enum.join(".")

  # The stamp test as SQL, the version inlined as a literal rather than a
  # bind: the partial `*_link_keys_stale_index`es carry this same predicate,
  # and Postgres can only prove a query uses one when the text matches. A
  # Unicode upgrade changes the literal, so those indexes stop matching (the
  # reads stay correct, they scan the basename index) until a migration
  # rebuilds them; `link_keys_index_test.exs` fails until it does.
  @link_keys_literal "'\\x" <> Base.encode16(@link_keys_version, case: :lower) <> "'::bytea"
  @keys_stale_sql "? IS DISTINCT FROM (? || " <> @link_keys_literal <> ")"
  @keys_current_sql "? IS NOT DISTINCT FROM (? || " <> @link_keys_literal <> ")"

  defmacrop keys_stale(stamp, nonce) do
    quote do: fragment(unquote(@keys_stale_sql), unquote(stamp), unquote(nonce))
  end

  defmacrop keys_current(stamp, nonce) do
    quote do: fragment(unquote(@keys_current_sql), unquote(stamp), unquote(nonce))
  end

  # The same test on wave 3's `notes.link_keys_v` (the trigger's smallint
  # reading of the stamp, major * 100 + minor), inlined for the same reason:
  # `notes_link_keys_stale` carries this literal.
  @link_keys_code @link_keys_version
                  |> String.split(".")
                  |> then(fn [major, minor | _] ->
                    String.to_integer(major) * 100 + String.to_integer(minor)
                  end)
  @keys_v_stale_sql "? IS DISTINCT FROM #{@link_keys_code}"
  @keys_v_current_sql "? = #{@link_keys_code}"

  defmacrop keys_v_stale(v), do: quote(do: fragment(unquote(@keys_v_stale_sql), unquote(v)))
  defmacrop keys_v_current(v), do: quote(do: fragment(unquote(@keys_v_current_sql), unquote(v)))

  @doc false
  # The Unicode version code `notes.link_keys_v` holds for current keys.
  def link_keys_code, do: @link_keys_code

  @doc """
  The link resolution keys a note or attachment row stores for `path`:
  `path_ci_hmac` (lowercased path, the folder-qualified lookup),
  `path_length` (graphemes, the first tiebreak), and `link_keys_stamp`.

  The stamp is the `path_nonce` the path was just encrypted under plus the
  Unicode version. Readers trust the keys only while the stamp equals the
  row's current nonce and version, so any writer that re-encrypts the path
  without recomputing them (a previous release mid-deploy or after a
  rollback, AAD rebind) invalidates them, and the row is decrypted instead.
  """
  @spec path_keys(binary(), String.t(), binary()) :: keyword()
  def path_keys(filter_key, path, path_nonce) do
    [
      path_ci_hmac: ci_hmac(filter_key, path),
      path_length: String.length(path),
      link_keys_stamp: path_nonce <> @link_keys_version
    ]
  end

  @doc "`path_keys/3` for a link edge: its `target_key_hmac` and stamp."
  @spec target_keys(binary(), String.t(), binary()) :: keyword()
  def target_keys(filter_key, target, target_nonce),
    do: [
      target_key_hmac: target_key_hmac(filter_key, target),
      link_keys_stamp: target_nonce <> @link_keys_version
    ]

  @doc "The version suffix of every `link_keys_stamp`."
  @spec link_keys_version() :: String.t()
  def link_keys_version, do: @link_keys_version

  @doc """
  The `target_key_hmac` a link edge stores for its raw `target`: the same
  lowercased key `path_keys/3` writes for a path, so an edge naming a path
  and the row at that path share it.
  """
  @spec target_key_hmac(binary(), String.t()) :: binary()
  def target_key_hmac(filter_key, target), do: ci_hmac(filter_key, target)

  defp keys_current?(stamp, nonce),
    do: is_binary(stamp) and is_binary(nonce) and stamp == nonce <> @link_keys_version

  # Own domain, so a lowercase path's key never equals its `path_hmac`.
  defp ci_hmac(filter_key, text),
    do: Crypto.hmac_field(filter_key, "ci\0" <> String.downcase(text))

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
  from `parsed` (as produced by `Engram.Links.Parser.extract/1`).
  Idempotent — safe to call on every note write.
  """
  @spec replace_links(map(), map(), binary(), [map()]) :: :ok
  def replace_links(user, vault, source_note_id, parsed) do
    _ = replace_links_basenames(user, vault, source_note_id, parsed)
    :ok
  end

  @doc """
  `replace_links/4`, returning the distinct `target_basename_hmac` of the
  written edges.

  When the new edges equal the stored ones (the common case: an edit that
  touched no link), the rows are left as they are instead of being deleted
  and re-inserted.
  """
  @spec replace_links_basenames(map(), map(), binary(), [map()]) :: [binary()]
  def replace_links_basenames(user, vault, source_note_id, parsed) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)

    with_hmacs = Enum.map(parsed, &{&1, Crypto.hmac_field(filter_key, basename_key(&1.target))})

    # `with_tenant` rather than a bare transaction: `note_links` carries FORCE
    # ROW LEVEL SECURITY, and the `skip_tenant_check: true` below silences only
    # Engram's own `prepare_query/3` guard — it sets nothing in Postgres.
    # Unscoped, the `insert_all` raises 42501 and the `delete_all` silently
    # matches zero rows, which is the worse half: a stale edge set survives a
    # rewrite with no error anywhere.
    #
    # Scoped HERE and not at the callers, deliberately. Callers such as
    # `ExtractNoteLinks` and `Rewriter.finish/4` reach this with no tenant in
    # force, or after their own tenant block has committed (a real top-level
    # transaction whose SET LOCAL is discarded at commit). Relying on a
    # caller's tenant only appears to work under the test sandbox, where
    # everything shares one outer transaction and the setting leaks forward.
    #
    # Re-entrant for the same tenant, so `RewriteNoteLinks` (which already
    # holds `with_tenant(user_id, ...)`) pays nothing.
    Repo.with_tenant!(user.id, fn ->
      # Serialize concurrent extraction for one source note. Two writers
      # (overlapping ExtractNoteLinks runs, a Rewriter repair, or duplicate
      # bulk jobs) interleaving this delete+insert under READ
      # COMMITTED can violate unique_index([:source_note_id, :position]):
      # B's DELETE cannot see A's uncommitted inserts. Both runs write a
      # freshly-parsed row set, so strict last-writer-wins under this lock
      # converges. Single lock per txn, taken first — no deadlock ordering.
      lock_source_note!(source_note_id)

      edges =
        Enum.map(with_hmacs, fn {p, hmac} ->
          {p.position, p.link_type, hmac, target_key_hmac(filter_key, p.target), p.target,
           p.alias, p.anchor, Crypto.row_version_aad_bound()}
        end)

      links_query =
        from(l in NoteLink,
          where:
            l.source_note_id == ^source_note_id and l.user_id == ^user.id and
              l.vault_id == ^vault.id
        )

      if stored_edges(links_query, dek) != Enum.sort(edges) do
        Repo.delete_all(links_query, skip_tenant_check: true)

        # Chunked, not one statement: the wire protocol caps a query at 65535
        # bind parameters, and a NoteLink row binds up to 15 of them (11 base +
        # the optional alias/anchor envelopes). One MOC-style note with a few
        # thousand wikilinks therefore overflows the limit, and Postgrex
        # answers that by KILLING the connection ("can not handle N
        # parameters"), not by returning a query error — so a single oversized
        # note costs a pooled connection and takes the whole extraction down
        # with it. Observed on a real vault at 145792 params (8576 links).
        # @insert_chunk keeps the worst case at 34k.
        now = DateTime.utc_now()

        edges
        |> Enum.map(&link_row(&1, user, vault, source_note_id, dek, now))
        |> Enum.chunk_every(@insert_chunk)
        |> Enum.each(&Repo.insert_all(NoteLink, &1, skip_tenant_check: true))
      end

      for {_pos, _type, hmac, _key, _t, _a, _n, _v} <- edges, uniq: true, do: hmac
    end)
  end

  @doc """
  The `target_basename_hmac`s among `hmacs` that some link in `parsed`
  names without resolving: the danglers a recent rename may explain.
  """
  @spec dangling_basenames(map(), map(), [map()], [binary()]) :: [binary()]
  def dangling_basenames(_user, _vault, _parsed, []), do: []

  def dangling_basenames(user, vault, parsed, hmacs) do
    user = reload_for_dek(user)
    {:ok, dek} = Crypto.get_dek(user)
    filter_key = Crypto.dek_filter_key_from_bytes(dek)
    wanted = MapSet.new(hmacs)

    targets =
      for p <- parsed,
          hmac = Crypto.hmac_field(filter_key, basename_key(p.target)),
          MapSet.member?(wanted, hmac),
          uniq: true,
          do: {hmac, p.target}

    Repo.with_tenant!(user.id, fn ->
      candidates = target_candidates(user, vault.id, targets, dek)

      for {hmac, target} <- targets,
          resolve_prefetched(candidates, hmac, target) == :dangling,
          uniq: true,
          do: hmac
    end)
  end

  # The stored edges in `replace_links_basenames/4`'s edge shape, sorted by
  # position (unique per source note). A field that fails to decrypt reads
  # :undecryptable, never nil: nil is an ABSENT alias/anchor, so a corrupt
  # envelope would compare equal to a link without one and survive every
  # re-extraction. The sentinel can only make the compare unequal.
  defp stored_edges(links_query, dek) do
    links_query
    |> Repo.all()
    |> Enum.map(fn l ->
      decrypt = fn
        nil, _nonce, _column ->
          nil

        ct, nonce, column ->
          decrypt_field(ct, nonce, dek, l.dek_version, :note_links, column, l.id) ||
            :undecryptable
      end

      # A key whose stamp no longer matches is not a key: compare unequal so
      # the next extraction rewrites the row with fresh ones.
      key =
        if keys_current?(l.link_keys_stamp, l.target_text_nonce),
          do: l.target_key_hmac,
          else: :stale

      {l.position, l.link_type, l.target_basename_hmac, key,
       decrypt.(l.target_text_ciphertext, l.target_text_nonce, :target_text),
       decrypt.(l.alias_ciphertext, l.alias_nonce, :alias),
       decrypt.(l.anchor_ciphertext, l.anchor_nonce, :anchor), l.dek_version}
    end)
    |> Enum.sort()
  end

  defp link_row(edge, user, vault, source_note_id, dek, now) do
    {position, link_type, hmac, key_hmac, target, alias_text, anchor_text, dek_version} = edge

    id = Engram.Notes.mint_id()

    {tct, tnonce} =
      Envelope.encrypt(target, dek, Crypto.aad_for_row(:note_links, :target_text, id))

    stamp = tnonce <> @link_keys_version

    %{
      id: id,
      user_id: user.id,
      vault_id: vault.id,
      source_note_id: source_note_id,
      target_text_ciphertext: tct,
      target_text_nonce: tnonce,
      target_basename_hmac: hmac,
      target_key_hmac: key_hmac,
      link_keys_stamp: stamp,
      link_type: link_type,
      position: position,
      dek_version: dek_version,
      inserted_at: now
    }
    |> put_optional_envelope(:alias, alias_text, dek, id)
    |> put_optional_envelope(:anchor, anchor_text, dek, id)
  end

  defp lock_source_note!(source_note_id), do: Repo.advisory_lock!(to_string(source_note_id))

  defp index_by_hmac(groups), do: Map.new(groups, fn {h, l} -> {h, index_candidates(l)} end)

  # Same extension-preference + cross-table-fallback rule as `resolve_target/4`,
  # reading from the prefetch instead of the DB.
  defp resolve_prefetched(candidates, hmac, target) do
    ext = target |> Path.basename() |> Path.extname() |> String.downcase()

    route_resolution(
      ext,
      fn -> candidates.notes |> Map.get(hmac, []) |> resolve_from_candidates(target, :note) end,
      fn ->
        candidates.attachments
        |> Map.get(hmac, [])
        |> resolve_from_candidates(target, :attachment)
      end
    )
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
  def resolve_target(user, vault, target, link_type) do
    # Both keys derived BEFORE the tenant scope, and THREADED through every
    # helper below. `Crypto.get_dek/1` reaches the key provider on a DekCache
    # miss — under `KEY_PROVIDER=aws_kms` an HTTPS round trip to KMS, with
    # `:kms_throttled` an explicit outcome — and inside the transaction
    # `with_tenant/2` opens that would hold a pooled connection for its
    # duration. `rls-enforcement-testing-traps.md` states the rule;
    # `replace_links/4` has always followed it.
    #
    # Threaded rather than relying on the derivation warming the ETS cache.
    # Warming makes the inner calls *probable* hits, not certain ones: the
    # cache has a TTL (default 1h) and three eviction paths that can land in
    # between — `UserDekRotation`, `AadRebind`, and the cross-node
    # `{:dek_evict, user_id}` broadcast, which deletes regardless of TTL.
    # `decrypt_and_group/3` needs the raw DEK, not the filter key, so passing
    # only the latter would leave that gap open.
    #
    # `dek_filter_key_from_bytes/1` rather than `dek_filter_key/1`: same HMAC,
    # one `get_dek/1` instead of two.
    {:ok, dek} = Crypto.get_dek(user)
    filter_key = Crypto.dek_filter_key_from_bytes(dek)

    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        do_resolve_target(user, vault, target, link_type, filter_key, dek)
      end)

    result
  end

  defp do_resolve_target(user, vault, target, _link_type, filter_key, dek) do
    key = basename_key(target)
    hmac = Crypto.hmac_field(filter_key, key)
    ext = target |> Path.basename() |> Path.extname() |> String.downcase()

    route_resolution(
      ext,
      fn -> resolve_note_target(user, vault, target, hmac, dek) end,
      fn -> resolve_attachment_target(user, vault, target, hmac, dek) end
    )
  end

  # Extension-preference + cross-table-fallback rule, shared by the
  # single-shot `resolve_target/4` path and the batch `resolve_prefetched/3`
  # path (#591 finding — was forked into two copies of this same if/else
  # before).
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

  defp resolve_note_target(user, vault, target, hmac, dek) do
    fetch_decrypted_candidates(user, vault, hmac, :notes, dek)
    |> resolve_from_candidates(target, :note)
  end

  defp resolve_attachment_target(user, vault, target, hmac, dek) do
    fetch_decrypted_candidates(user, vault, hmac, :attachments, dek)
    |> resolve_from_candidates(target, :attachment)
  end

  # Query + decrypt only (no target-dependent filtering) — the part that's
  # IDENTICAL for every target sharing an hmac.
  defp fetch_decrypted_candidates(user, vault, hmac, table, dek) do
    user
    |> fetch_candidates_by_hmac(vault, [hmac], table, dek)
    |> Map.get(hmac, [])
  end

  # Batch form: `%{basename_hmac => [{id, decrypted_path}]}` for a set of
  # hmacs, one query per table. `fetch_decrypted_candidates/5` is the
  # single-hmac projection of this.
  defp fetch_candidates_by_hmac(user, vault, hmacs, :notes, dek) do
    ids? = Keys.ids?()

    from(n in Note,
      where:
        n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
          is_nil(n.deleted_at),
      where: ^Keys.in_any(:basename, hmacs, ids?),
      where: ^Keys.kind_match(:note, ids?),
      select: %{
        id: n.id,
        basename_hmac: n.basename_hmac,
        path_ciphertext: n.path_ciphertext,
        path_nonce: n.path_nonce,
        dek_version: n.dek_version
      }
    )
    |> Repo.all(skip_tenant_check: true)
    |> decrypt_and_group(dek, :notes)
  end

  defp fetch_candidates_by_hmac(user, vault, hmacs, :attachments, dek) do
    from(a in Attachment,
      where:
        a.user_id == ^user.id and a.vault_id == ^vault.id and
          a.basename_hmac in ^hmacs and is_nil(a.deleted_at),
      select: %{
        id: a.id,
        basename_hmac: a.basename_hmac,
        path_ciphertext: a.path_ciphertext,
        path_nonce: a.path_nonce,
        dek_version: a.dek_version
      }
    )
    |> Repo.all(skip_tenant_check: true)
    |> decrypt_and_group(dek, :attachments)
  end

  # Takes the DEK rather than deriving it. Every caller reaches here from
  # inside a `Repo.with_tenant/2` closure, and this used to call
  # `Crypto.get_dek/1` itself — so a DekCache miss went to the KMS provider
  # while holding the tenant transaction's connection. The public entry points
  # derive it before opening the scope and thread it down; see the note on
  # `resolve_target/4`.
  #
  # Rows that fail to decrypt are dropped, same as before. Grouping reverses
  # each bucket's query order, which `resolve_from_candidates/3` cannot
  # observe: `index_candidates/1` sorts on `{String.length(path), path}`, and live rows in one
  # vault have distinct paths, so that ordering is total and no stable-sort tie
  # survives to break.
  defp decrypt_and_group([], _dek, _table), do: %{}

  defp decrypt_and_group(rows, dek, table) do
    paths = decrypt_column(rows, dek, table, :path, &{&1.path_ciphertext, &1.path_nonce})

    rows
    |> Enum.zip(paths)
    |> Enum.reduce(%{}, fn
      {_row, nil}, acc ->
        acc

      {row, path}, acc ->
        Map.update(acc, row.basename_hmac, [{row.id, path}], &[{row.id, path} | &1])
    end)
  end

  @doc """
  Indexes a `pre_rename_candidates/5` result for repeated
  `pre_rename_winner?/4` calls, so a walk over many occurrences pays the
  sort once instead of once per occurrence.
  """
  @spec index_candidate_sets(%{notes: list(), attachments: list()}) :: %{
          notes: candidate_index(),
          attachments: candidate_index()
        }
  def index_candidate_sets(%{notes: notes, attachments: attachments}),
    do: %{notes: index_candidates(notes), attachments: index_candidates(attachments)}

  # The tiebreak order and the case-insensitive path lookup, built ONCE per
  # candidate set. Callers that resolve many targets against one shared set
  # (`resolve_edges/4`, `replace_links/4`'s prefetch) index it once
  # and then pay O(1) per target. Re-sorting per target made a rebind over a
  # basename shared by C notes with E inbound edges O(E * C log C): 733
  # `index.md` notes x 1,787 edges pinned the prod worker (2026-10-18).
  #
  # The order is `{String.length(path), path}`: shortest path wins, ties break
  # lexicographically. Live rows in one vault have distinct paths, so it is
  # total. `by_path` keeps the best-ranked row per lowercased path, so a
  # folder target's winner is the lowest rank among its variants' hits.
  defp index_candidates(candidates) do
    sorted = Enum.sort_by(candidates, fn {_id, path} -> {String.length(path), path} end)

    by_path =
      sorted
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{id, path}, rank}, acc ->
        Map.put_new(acc, String.downcase(path), {rank, id})
      end)

    %{sorted: sorted, by_path: by_path}
  end

  # Target-dependent filter + tiebreak — the part that varies per edge even
  # when the candidate set (fetched above) is shared. A raw list is indexed
  # here, for one-shot callers; loops pass a prebuilt index.
  defp resolve_from_candidates(candidates, target, tag) when is_list(candidates),
    do: candidates |> index_candidates() |> resolve_from_candidates(target, tag)

  # A target with a folder segment narrows candidates to a full-path match
  # (case-insensitive, also trying `.md`/`.canvas` appended); a bare basename
  # target takes the best-ranked same-basename candidate.
  defp resolve_from_candidates(%{sorted: sorted, by_path: by_path}, target, tag) do
    if String.contains?(target, "/") do
      variants = Enum.map(["" | @note_exts], &String.downcase(target <> &1))

      variants
      |> Enum.flat_map(fn variant ->
        case Map.fetch(by_path, variant) do
          {:ok, hit} -> [hit]
          :error -> []
        end
      end)
      |> case do
        [] -> suffix_match(sorted, variants, tag)
        hits -> {tag, hits |> Enum.min() |> elem(1)}
      end
    else
      case sorted do
        [] -> :dangling
        [{id, _path} | _] -> {tag, id}
      end
    end
  end

  # Obsidian resolves a qualified link that names no exact path to a file
  # whose path ENDS with it at a folder boundary, so `[[Folder/Note]]` finds
  # `Projects/Folder/Note.md`. `sorted` is shortest first, so the first hit
  # is the same winner the bare-name rule would pick among those paths.
  defp suffix_match(sorted, variants, tag) do
    suffixes = Enum.map(variants, &("/" <> &1))

    case Enum.find(sorted, fn {_id, path} ->
           String.ends_with?(String.downcase(path), suffixes)
         end) do
      nil -> :dangling
      {id, _path} -> {tag, id}
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
    # Outside the scope: see `resolve_target/4` above.
    {:ok, filter_key} = Crypto.dek_filter_key(user)

    {:ok, result} =
      Repo.with_tenant(user.id, fn -> do_live_basename_count(user, vault, key, filter_key) end)

    result
  end

  defp do_live_basename_count(user, vault, key, filter_key) do
    hmac = Crypto.hmac_field(filter_key, key)
    ids? = Keys.ids?()

    notes =
      Repo.one(
        from(n in Note,
          where:
            n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
              is_nil(n.deleted_at),
          where: ^Keys.eq(:basename, hmac, ids?),
          where: ^Keys.kind_match(:note, ids?),
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
  Reconstructed pre-rename candidate sets for a rename target: current live
  candidates for `old_path`'s basename hmac, minus the renamed row's
  post-rename position, plus a synthetic candidate `{renamed_id, old_path}`
  in the `kind` list. Everything here is CONSTANT across a whole rename
  walk (the hmac comes from `old_path`, not from any occurrence), so
  callers fetch ONCE per job batch — `Rewriter.build_target/5` stashes the
  result on the target map — and thread it through
  `pre_rename_winner?/4` per occurrence.

  Snapshot semantics: candidate-table changes AFTER the fetch (a concurrent
  rename/create sharing the basename) aren't seen for the rest of the
  batch. That's the walk's pre-existing eventual-consistency posture — no
  transaction spans the batch, and later rebinds/renames self-heal — just
  a wider window than the old per-occurrence refetch had.
  """
  @spec pre_rename_candidates(map(), map(), :note | :attachment, binary(), String.t()) ::
          %{notes: [{binary(), String.t()}], attachments: [{binary(), String.t()}]}
  def pre_rename_candidates(user, vault, kind, renamed_id, old_path) do
    # Outside the scope and threaded down: see `resolve_target/4` above. Both
    # keys are needed here — the filter key for the hmac, the raw DEK because
    # `fetch_decrypted_candidates/5` decrypts a path per candidate row, once
    # per table.
    {:ok, dek} = Crypto.get_dek(user)
    filter_key = Crypto.dek_filter_key_from_bytes(dek)

    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        do_pre_rename_candidates(user, vault, kind, renamed_id, old_path, filter_key, dek)
      end)

    result
  end

  defp do_pre_rename_candidates(user, vault, kind, renamed_id, old_path, filter_key, dek) do
    hmac = Crypto.hmac_field(filter_key, basename_key(old_path))

    notes =
      user
      |> fetch_decrypted_candidates(vault, hmac, :notes, dek)
      |> Enum.reject(fn {id, _path} -> id == renamed_id end)

    attachments =
      user
      |> fetch_decrypted_candidates(vault, hmac, :attachments, dek)
      |> Enum.reject(fn {id, _path} -> id == renamed_id end)

    case kind do
      :note -> %{notes: [{renamed_id, old_path} | notes], attachments: attachments}
      :attachment -> %{notes: notes, attachments: [{renamed_id, old_path} | attachments]}
    end
  end

  @doc """
  Would `target` have resolved to the renamed row (`renamed_id`) at its OLD
  path, under `resolve_target/4`'s rules? `candidates` comes from
  `pre_rename_candidates/5` — fetched once per job batch and shared
  across every occurrence; only the per-occurrence `target` varies the
  resolution (extension routing, path filter, tiebreak), applied via the
  same `route_resolution/3` + `resolve_from_candidates/3` rules
  `resolve_target/4` uses.
  """
  @spec pre_rename_winner?(String.t(), String.t(), binary(), %{
          notes: [{binary(), String.t()}] | candidate_index(),
          attachments: [{binary(), String.t()}] | candidate_index()
        }) :: boolean()
  def pre_rename_winner?(target, old_path, renamed_id, %{notes: notes, attachments: attachments}) do
    if basename_key(target) != basename_key(old_path) do
      false
    else
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
  Convenience form of `pre_rename_winner?/4` that fetches the candidate
  sets itself (via `pre_rename_candidates/5`) and delegates. One
  fetch+decrypt pass per call — fine for a single question, wasteful in a
  loop; walk-shaped callers (`Rewriter.plan_edits/5`) use the prefetched
  form. Semantics are pinned by the unit tests against THIS arity.
  """
  @spec pre_rename_winner?(map(), map(), String.t(), :note | :attachment, binary(), String.t()) ::
          boolean()
  def pre_rename_winner?(user, vault, target, kind, renamed_id, old_path) do
    if basename_key(target) != basename_key(old_path) do
      false
    else
      pre_rename_winner?(
        target,
        old_path,
        renamed_id,
        pre_rename_candidates(user, vault, kind, renamed_id, old_path)
      )
    end
  end

  @doc """
  Computes the HMAC for a `basename_key/1` result under `user`'s filter key.
  Callers that put it in a job (`RewriteNoteLinks`) compute it from
  plaintext they already have in scope, so `oban_jobs.args` carries only the
  opaque HMAC — never the plaintext basename (T3.2/H3 invariant).
  """
  # KNOWN GAP, not fixed here. This derives the filter key itself, so it
  # reaches `Crypto.get_dek/1` and — on a DekCache miss under
  # `KEY_PROVIDER=aws_kms` — the KMS provider. Four call sites run it from
  # INSIDE an enclosing `Repo.with_tenant/2`: `Notes.genesis_relocate_live/6`
  # (notes.ex:1308, :1319) and `Notes.do_rename_note_inner/5` (notes.ex:2857,
  # :2864), both deliberately in-transaction so the rebind job commits
  # atomically with the rename. So the rename path still carries the defect the
  # nine wrapped entry points no longer do.
  #
  # Left alone because fixing it means threading a key through
  # `genesis_relocate_live/6` and `do_rename_note_inner/5` in `notes.ex`, which
  # this change-set does not otherwise touch, and re-verifying the rename
  # paths. Its own change, with its own tests — not a silent omission.
  @spec basename_hmac(Engram.Accounts.User.t(), String.t()) :: binary()
  def basename_hmac(user, key) do
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    Crypto.hmac_field(filter_key, key)
  end

  @doc """
  A note was soft-deleted: drop its outgoing edges (they're meaningless
  once the source is gone). Incoming edges need nothing: targets resolve on
  read, and a deleted note is no candidate.
  """
  @spec on_note_soft_deleted(binary(), binary()) :: :ok
  def on_note_soft_deleted(user_id, note_id) do
    # A DELETE is filtered rather than rejected without a tenant (only INSERTs
    # raise), so unscoped this would return :ok having dropped nothing.
    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        Repo.delete_all(
          from(l in NoteLink, where: l.user_id == ^user_id and l.source_note_id == ^note_id),
          skip_tenant_check: true
        )
      end)

    :ok
  end

  @doc """
  Decrypted outgoing links for a note, in parser order.
  """
  @spec links_for_note(map(), binary()) :: [map()]
  def links_for_note(user, note_id),
    do: user |> links_for_notes([note_id]) |> Map.fetch!(note_id)

  @doc """
  `links_for_note/2` for many notes in one pass: `%{note_id => links}`, every
  id present. The edges, their targets and the target paths each cost one
  query for the whole set, not one per note.
  """
  @spec links_for_notes(map(), [binary()]) :: %{binary() => [map()]}
  def links_for_notes(user, note_ids) do
    # Both outside the scope: see `resolve_target/4` above. `reload_for_dek/1`
    # reads `users`, which carries no RLS policy, so it does not need the
    # tenant. This is the hottest of the nine — `note_json/2` calls it on every
    # single-note response.
    user = reload_for_dek(user)
    {:ok, dek} = Crypto.get_dek(user)
    note_ids = Enum.uniq(note_ids)

    Repo.with_tenant!(user.id, fn -> do_links_for_notes(user, note_ids, dek) end)
  end

  defp do_links_for_notes(user, note_ids, dek) do
    edges =
      Repo.all(
        from(l in NoteLink,
          where: l.user_id == ^user.id and l.source_note_id in ^note_ids,
          order_by: [l.source_note_id, l.position],
          select: map(l, ^@edge_read_fields)
        ),
        skip_tenant_check: true
      )

    texts = target_texts(edges, dek)

    # `resolve_edges/4` takes one vault at a time.
    {resolved, note_paths} =
      edges
      |> Enum.zip(texts)
      |> Enum.group_by(fn {edge, _text} -> edge.vault_id end)
      |> Enum.reduce({%{}, %{}}, fn {_vault, pairs}, {resolved, paths} ->
        {vault_edges, vault_texts} = Enum.unzip(pairs)
        {hits, candidates} = resolve_edges(user, vault_edges, vault_texts, dek)

        {Map.merge(resolved, Map.new(Enum.zip(Enum.map(vault_edges, & &1.id), hits))),
         Map.merge(paths, candidate_paths(candidates.notes))}
      end)

    note_paths =
      for({_edge, {:note, id}} <- resolved, not Map.has_key?(note_paths, id), do: id)
      |> Enum.uniq()
      |> then(&Map.merge(note_paths, note_paths_by_id(user, &1, dek)))

    by_note =
      edges
      |> Enum.zip(texts)
      |> Enum.group_by(
        fn {edge, _text} -> edge.source_note_id end,
        fn {edge, text} ->
          render_link(edge, text, Map.fetch!(resolved, edge.id), note_paths, dek)
        end
      )

    Map.new(note_ids, &{&1, Map.get(by_note, &1, [])})
  end

  defp render_link(edge, text, resolution, note_paths, dek) do
    {target_note_id, target_attachment_id} = target_ids(resolution)

    %{
      target_text: text,
      target_note_id: target_note_id,
      target_attachment_id: target_attachment_id,
      target_path: target_note_id && Map.get(note_paths, target_note_id),
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
      dangling: resolution == :dangling
    }
  end

  # Link targets are resolved on read, never stored-and-maintained: an edge
  # keeps its target's NAME (`target_basename_hmac` + `target_text`), and the
  # vault's live notes and attachments decide what it points at right now.
  # Creating, renaming, deleting or restoring a note therefore rewrites no
  # other note's edges (that fan-out pinned the prod worker on 2026-10-18:
  # 733 `index.md` notes, 1,787 edges to `index`).
  #
  # Each table answers one query holding only what can decide a link: the
  # shortest same-name rows (bare links), the rows whose lowercased path a
  # folder-qualified link names, and rows written before those keys existed.
  # Those rows go through the same `resolve_prefetched/3` rules as a full
  # candidate set, so the answer is identical. Edges with the same target
  # resolve once. All `edges` must share one vault.
  defp resolve_edges(_user, [], _texts, _dek), do: {[], %{notes: %{}, attachments: %{}}}

  defp resolve_edges(user, [first | _] = edges, texts, dek) do
    targets =
      for {edge, text} <- Enum.zip(edges, texts),
          is_binary(text),
          do: {edge.target_basename_hmac, text}

    candidates = target_candidates(user, first.vault_id, targets, dek)

    {resolved, _memo} =
      edges
      |> Enum.zip(texts)
      |> Enum.map_reduce(%{}, fn
        # A target that will not decrypt has no name to resolve.
        {_edge, nil}, memo ->
          {:dangling, memo}

        {edge, text}, memo ->
          key = {edge.target_basename_hmac, text}

          case memo do
            %{^key => hit} ->
              {hit, memo}

            _ ->
              hit = resolve_prefetched(candidates, edge.target_basename_hmac, text)
              {hit, Map.put(memo, key, hit)}
          end
      end)

    {resolved, candidates}
  end

  # `[{basename_hmac, target_text}]` -> the indexed candidate sets
  # `resolve_prefetched/3` needs to resolve every one of them.
  defp target_candidates(_user, _vault_id, [], _dek), do: %{notes: %{}, attachments: %{}}

  defp target_candidates(user, vault_id, targets, dek) do
    filter_key = Crypto.dek_filter_key_from_bytes(dek)
    {bare, pathed} = Enum.split_with(targets, fn {_h, t} -> not String.contains?(t, "/") end)

    keys = %{
      hmacs: targets |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
      bare_hmacs: bare |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
      path_keys:
        pathed |> Enum.flat_map(fn {_h, t} -> variant_keys(filter_key, t) end) |> Enum.uniq()
    }

    rows =
      [:notes, :attachments]
      |> Enum.flat_map(&candidate_queries(user.id, vault_id, keys, &1))
      |> Enum.reduce(fn part, acc -> union_all(acc, ^part) end)
      |> Repo.all(skip_tenant_check: true)
      |> Enum.uniq_by(&{&1.table, &1.id})

    raw =
      for {table, tag} <- [notes: 1, attachments: 2], into: %{} do
        {table, rows |> Enum.filter(&(&1.table == tag)) |> decrypt_and_group(dek, table)}
      end

    indexed = index_groups(raw)

    # A folder-qualified link that names no exact path can still name the
    # END of one (`[[Folder/Note]]` -> `Projects/Folder/Note.md`), which the
    # keyed lookup above cannot see: a suffix has no HMAC. Only those misses
    # pay for every same-named row of their basename, once per call.
    # ponytail: a hub basename (733 `index.md`) costs one fetch + decrypt of
    # all its rows when a qualified link to it misses; a suffix key per path
    # depth would make it an index probe if that ever shows up in traces.
    # Any qualified target without an EXACT path hit, not only a dangling one:
    # a suffix match against the partial set above can pick a row that loses
    # to a shorter one the keyed lookup never fetched, and backlinks would
    # then credit one link to two notes.
    case for({h, t} <- pathed, not exact_path_hit?(indexed, h, t), uniq: true, do: h) do
      [] ->
        indexed

      missed ->
        raw
        |> Map.new(fn {table, groups} ->
          all = fetch_candidates_by_hmac(user, %{id: vault_id}, missed, table, dek)
          {table, Map.merge(groups, all, fn _hmac, a, b -> Enum.uniq(a ++ b) end)}
        end)
        |> index_groups()
    end
  end

  defp exact_path_hit?(indexed, hmac, target) do
    variants = Enum.map(["" | @note_exts], &String.downcase(target <> &1))

    Enum.any?(Map.values(indexed), fn by_hmac ->
      case by_hmac do
        %{^hmac => %{by_path: by_path}} -> Enum.any?(variants, &Map.has_key?(by_path, &1))
        _ -> false
      end
    end)
  end

  defp index_groups(raw),
    do: Map.new(raw, fn {table, groups} -> {table, index_by_hmac(groups)} end)

  # The `path_ci_hmac`s a folder-qualified `target` can match: the target as
  # written, and with each note extension appended.
  defp variant_keys(filter_key, target),
    do: Enum.map(["" | @note_exts], &target_key_hmac(filter_key, target <> &1))

  # Three parts per table, each on its own index, so a hub basename (733
  # `index.md` rows in the 2026-10-18 incident) costs a few index probes,
  # not a pass over every same-name row:
  #
  #   * stale: keys missing or stale, decrypted and resolved like any row
  #     (`*_link_keys_stale_index`, empty once the backfill has run);
  #   * pathed: current rows whose lowercased path a folder-qualified link
  #     names (`path_ci_hmac`);
  #   * shortest: per bare basename, the current rows of the shortest
  #     length (`basename_hmac, path_length`). The minimum is over current
  #     rows only: a stale length could hide the real winner, and stale rows
  #     come back through the first part anyway.
  #
  # `table` tags the row (1 notes, 2 attachments). Runs inside the caller's
  # tenant transaction.
  defp candidate_queries(user_id, vault_id, keys, :notes) do
    if Keys.ids?(),
      do: note_candidate_queries(user_id, vault_id, keys),
      else: hmac_candidate_queries(user_id, vault_id, keys, :notes)
  end

  defp candidate_queries(user_id, vault_id, keys, :attachments),
    do: hmac_candidate_queries(user_id, vault_id, keys, :attachments)

  # The three parts on wave 3's notes keys (`notes_link_keys_stale`,
  # `notes_path_ci`, `notes_basename`): 16-byte ids, the int2 key version,
  # and the shortest length from `notes_basename`. Same rows as
  # the HMAC form; the projection keeps `basename_hmac` for the grouping.
  defp note_candidate_queries(user_id, vault_id, keys) do
    to_ids = &Enum.map(&1, fn hmac -> Keys.id(hmac) end)

    {hmacs, path_keys, bare} =
      {to_ids.(keys.hmacs), to_ids.(keys.path_keys), to_ids.(keys.bare_hmacs)}

    live =
      from(c in Note,
        where:
          c.user_id == ^user_id and c.vault_id == ^vault_id and is_nil(c.deleted_at) and
            c.kind == "note" and not c.is_folder,
        select: %{
          table: fragment("?::integer", 1),
          id: c.id,
          basename_hmac: c.basename_hmac,
          path_ciphertext: c.path_ciphertext,
          path_nonce: c.path_nonce,
          dek_version: c.dek_version
        }
      )

    stale =
      where(
        live,
        [c],
        c.basename_id in type(^hmacs, {:array, Ecto.UUID}) and not is_nil(c.basename_id) and
          keys_v_stale(c.link_keys_v)
      )

    pathed =
      where(
        live,
        [c],
        c.path_ci_id in type(^path_keys, {:array, Ecto.UUID}) and
          c.basename_id in type(^hmacs, {:array, Ecto.UUID}) and keys_v_current(c.link_keys_v)
      )

    shortest_len =
      from(m in Note,
        where:
          m.user_id == ^user_id and m.vault_id == ^vault_id and
            m.basename_id in type(^bare, {:array, Ecto.UUID}) and is_nil(m.deleted_at) and
            m.kind == "note" and not m.is_folder and keys_v_current(m.link_keys_v),
        group_by: m.basename_id,
        select: %{basename_id: m.basename_id, len: min(m.path_len)}
      )

    shortest =
      join(live, :inner, [c], s in subquery(shortest_len),
        on:
          c.basename_id == s.basename_id and c.path_len == s.len and
            keys_v_current(c.link_keys_v)
      )

    [stale, pathed, shortest]
  end

  defp hmac_candidate_queries(user_id, vault_id, keys, table) do
    {schema, tag} = if table == :notes, do: {Note, 1}, else: {Attachment, 2}

    live =
      from(c in schema,
        where: c.user_id == ^user_id and c.vault_id == ^vault_id and is_nil(c.deleted_at),
        select: %{
          table: fragment("?::integer", ^tag),
          id: c.id,
          basename_hmac: c.basename_hmac,
          path_ciphertext: c.path_ciphertext,
          path_nonce: c.path_nonce,
          dek_version: c.dek_version
        }
      )

    live = if table == :notes, do: where(live, [c], c.kind == "note"), else: live

    stale =
      where(
        live,
        [c],
        c.basename_hmac in ^keys.hmacs and not is_nil(c.basename_hmac) and
          keys_stale(c.link_keys_stamp, c.path_nonce)
      )

    pathed =
      where(
        live,
        [c],
        c.path_ci_hmac in ^keys.path_keys and c.basename_hmac in ^keys.hmacs and
          keys_current(c.link_keys_stamp, c.path_nonce)
      )

    # Grouped, not LATERAL per basename: Postgres's generic plan for a
    # cached statement re-ran a correlated minimum once per row (650 ms on
    # the hub fixture against 10 ms custom).
    shortest_len =
      from(m in schema,
        where:
          m.user_id == ^user_id and m.vault_id == ^vault_id and
            m.basename_hmac in ^keys.bare_hmacs and is_nil(m.deleted_at) and
            keys_current(m.link_keys_stamp, m.path_nonce),
        group_by: m.basename_hmac,
        select: %{basename_hmac: m.basename_hmac, len: min(m.path_length)}
      )

    shortest_len =
      if table == :notes, do: where(shortest_len, [m], m.kind == "note"), else: shortest_len

    shortest =
      join(live, :inner, [c], s in subquery(shortest_len),
        on:
          c.basename_hmac == s.basename_hmac and c.path_length == s.len and
            keys_current(c.link_keys_stamp, c.path_nonce)
      )

    [stale, pathed, shortest]
  end

  defp note_paths_by_id(_user, [], _dek), do: %{}

  defp note_paths_by_id(user, ids, dek) do
    rows =
      Repo.all(
        from(n in Note,
          where: n.user_id == ^user.id and n.kind == "note" and n.id in ^ids,
          select: map(n, [:id, :path_ciphertext, :path_nonce, :dek_version])
        ),
        skip_tenant_check: true
      )

    paths = decrypt_column(rows, dek, :notes, :path, &{&1.path_ciphertext, &1.path_nonce})
    for {row, path} <- Enum.zip(rows, paths), is_binary(path), into: %{}, do: {row.id, path}
  end

  defp target_ids({:note, id}), do: {id, nil}
  defp target_ids({:attachment, id}), do: {nil, id}
  defp target_ids(:dangling), do: {nil, nil}

  defp candidate_paths(indexed) do
    for {_hmac, %{sorted: sorted}} <- indexed, {id, path} <- sorted, into: %{}, do: {id, path}
  end

  defp target_texts(edges, dek) do
    decrypt_column(edges, dek, :note_links, :target_text, fn e ->
      {e.target_text_ciphertext, e.target_text_nonce}
    end)
  end

  # One column across `rows` in one native call (rows carry `id` and
  # `dek_version`; `field` returns `{ciphertext, nonce}`). A batch with a bad
  # row falls back to per-row decrypts, which log it and yield nil for it
  # alone. ponytail: one bad row costs that read the per-row path; split the
  # batch around it if it ever shows in the decrypt metrics.
  defp decrypt_column([], _dek, _table, _column, _field), do: []

  defp decrypt_column(rows, dek, table, column, field) do
    fields =
      Enum.map(rows, fn row ->
        {ct, nonce} = field.(row)
        {Ecto.UUID.dump!(row.id), Crypto.aad_bound?(row.dek_version), ct, nonce}
      end)

    case Enum.all?(fields, &is_binary(elem(&1, 2))) &&
           Envelope.decrypt_many(dek, Crypto.aad_prefix(table, column), fields) do
      {:ok, plain} ->
        plain

      _ ->
        Enum.map(rows, fn row ->
          {ct, nonce} = field.(row)
          decrypt_field(ct, nonce, dek, row.dek_version, table, column, row.id)
        end)
    end
  end

  @doc """
  Max edges `backlinks_for_note/2` returns by default. Exposed so tests and
  callers (e.g. the OpenAPI schema description) can assert against the real
  value instead of hardcoding `200` a second place.
  """
  @spec backlinks_limit() :: pos_integer()
  def backlinks_limit, do: @backlinks_limit

  @doc """
  Decrypted incoming links (backlinks) for a note — one entry per edge
  pointing at it, carrying the source note's decrypted path/title.

  Capped at `backlinks_limit/0` edges (default #{@backlinks_limit}). A
  heavily-linked note (e.g. a MOC/hub note) could otherwise return an
  unbounded response. Ordered by `position, id` so the cap is stable
  across calls; that same ordering is what a future keyset-paginated
  version of this function would page on.

  `opts[:limit]` overrides the cap for this call only (e.g. `limit: n + 1`
  to detect truncation without an unbounded COUNT); omitting it keeps every
  existing caller's behavior unchanged.

  `opts[:distinct_sources]` (default `false`), when `true`, returns at most
  one row per distinct `source_note_id` instead of one row per edge. A
  single source note can link to the same target more than once (several
  edges, one source), so counting raw edges against `limit + 1` cannot tell
  "more edges" from "more distinct linking notes". get_notes' truncation
  probe needs the latter.
  """
  @spec backlinks_for_note(map(), binary(), keyword()) :: [map()]
  def backlinks_for_note(user, note_id, opts \\ []),
    do: user |> backlinks_for_notes([note_id], opts) |> Map.fetch!(note_id)

  @doc """
  `backlinks_for_note/3` for many notes in one pass: `%{note_id => backlinks}`,
  every id present, `opts` applied per note. The names, their candidates,
  the incoming edges and the source notes each cost one query for the whole
  set, not one per note.
  """
  @spec backlinks_for_notes(map(), [binary()], keyword()) :: %{binary() => [map()]}
  def backlinks_for_notes(user, note_ids, opts \\ []) do
    # Both outside the scope: see `resolve_target/4` above.
    user = reload_for_dek(user)
    {:ok, dek} = Crypto.get_dek(user)
    limit = Keyword.get(opts, :limit, backlinks_limit())
    distinct? = Keyword.get(opts, :distinct_sources, false)
    note_ids = Enum.uniq(note_ids)

    Repo.with_tenant!(user.id, fn ->
      do_backlinks(user, note_ids, live_note_names(user, note_ids, dek), dek, limit, distinct?)
    end)
  end

  @doc """
  Notes that link to or embed the attachment `attachment_id`, resolved by name
  the same way `backlinks_for_note/3` resolves a note's, so a link written
  before the file was uploaded still counts. One row per linking note, capped
  at `backlinks_limit/0`. Empty when the attachment is not in `vault_id`.
  """
  @spec backlinks_for_attachment(map(), binary(), binary()) :: [map()]
  def backlinks_for_attachment(user, vault_id, attachment_id) do
    in_vault? =
      Repo.with_tenant!(user.id, fn ->
        Repo.exists?(
          from(a in Attachment,
            where: a.user_id == ^user.id and a.vault_id == ^vault_id and a.id == ^attachment_id
          ),
          skip_tenant_check: true
        )
      end)

    # The key only after the check: a user who has stored nothing has no DEK
    # yet, and any id they ask about is someone else's or nobody's.
    if in_vault? do
      user = reload_for_dek(user)
      {:ok, dek} = Crypto.get_dek(user)
      ids = [attachment_id]

      user.id
      |> Repo.with_tenant!(fn ->
        names = live_attachment_names(user, ids, dek)
        do_backlinks(user, ids, names, dek, backlinks_limit(), true)
      end)
      |> Map.fetch!(attachment_id)
    else
      []
    end
  end

  # `names` are the live targets among `ids` (notes or attachments), each
  # `%{id, target, vault_id, hmac, path}`.
  defp do_backlinks(user, ids, names, dek, limit, distinct?) do
    filter_key = Crypto.dek_filter_key_from_bytes(dek)

    names =
      for {name, targets} <- winning_targets(user, names, dek) do
        Map.merge(name, %{
          targets: MapSet.new(targets),
          keys: MapSet.new(targets, &target_key_hmac(filter_key, &1))
        })
      end

    edges = incoming_edges(user, names, limit, distinct?)
    {_keyed, unkeyed} = Enum.split_with(edges, &keyed?/1)

    texts =
      Map.new(Enum.zip(unkeyed, target_texts(unkeyed, dek)), fn {edge, text} ->
        {edge.id, text && String.downcase(text)}
      end)

    picked =
      Map.new(names, fn name ->
        mine =
          edges
          |> Enum.filter(&links_to?(&1, name, texts))
          |> Enum.sort_by(&{&1.position, &1.id})
          |> pick_backlinks(limit, distinct?)

        {name.id, mine}
      end)

    rendered =
      picked
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq_by(& &1.id)
      |> then(&Enum.zip(Enum.map(&1, fn edge -> edge.id end), render_backlinks(&1, user, dek)))
      |> Map.new()

    Map.new(ids, fn id ->
      {id, picked |> Map.get(id, []) |> Enum.map(&Map.fetch!(rendered, &1.id))}
    end)
  end

  defp keyed?(edge), do: keys_current?(edge.link_keys_stamp, edge.target_text_nonce)

  # Keyed edges match by key. The rest (written before the keys existed, or
  # re-encrypted by a writer that does not know them) match by their
  # decrypted text; the `LinkResolutionKeys` data migration empties that set.
  # An edge whose text will not decrypt matches nothing.
  defp links_to?(edge, name, texts) do
    edge.vault_id == name.vault_id and edge.target_basename_hmac == name.hmac and
      if keyed?(edge),
        do: MapSet.member?(name.keys, edge.target_key_hmac),
        else: MapSet.member?(name.targets, Map.get(texts, edge.id))
  end

  # The live notes among `note_ids` with a name: `%{id, vault_id, hmac,
  # path}`. A deleted note is no candidate, so it has no backlinks. A note
  # whose path will not decrypt has no name to match, so none either.
  defp live_note_names(user, note_ids, dek) do
    rows =
      Repo.all(
        from(n in Note,
          where:
            n.user_id == ^user.id and n.id in ^note_ids and n.kind == "note" and
              is_nil(n.deleted_at) and not is_nil(n.basename_hmac),
          select:
            map(n, [:id, :vault_id, :basename_hmac, :path_ciphertext, :path_nonce, :dek_version])
        ),
        skip_tenant_check: true
      )

    paths = decrypt_column(rows, dek, :notes, :path, &{&1.path_ciphertext, &1.path_nonce})

    for {n, path} <- Enum.zip(rows, paths),
        is_binary(path),
        do: %{
          id: n.id,
          target: {:note, n.id},
          vault_id: n.vault_id,
          hmac: n.basename_hmac,
          path: path
        }
  end

  # `live_note_names/3` for attachments: the live ones among `ids` whose path
  # decrypts.
  defp live_attachment_names(user, ids, dek) do
    rows =
      Repo.all(
        from(a in Attachment,
          where:
            a.user_id == ^user.id and a.id in ^ids and is_nil(a.deleted_at) and
              not is_nil(a.basename_hmac),
          select:
            map(a, [:id, :vault_id, :basename_hmac, :path_ciphertext, :path_nonce, :dek_version])
        ),
        skip_tenant_check: true
      )

    paths = decrypt_column(rows, dek, :attachments, :path, &{&1.path_ciphertext, &1.path_nonce})

    for {a, path} <- Enum.zip(rows, paths),
        is_binary(path),
        do: %{
          id: a.id,
          target: {:attachment, a.id},
          vault_id: a.vault_id,
          hmac: a.basename_hmac,
          path: path
        }
  end

  # Per name, every lowercased target text that resolves to that note (or
  # attachment). A link
  # resolves the same however its target is cased, and it can only reach a
  # note by its basename (bare) or by its full path (folder-qualified), so
  # these few candidates, run through the read-time rules, are the whole
  # answer. One candidate fetch per vault.
  defp winning_targets(user, names, dek) do
    names
    |> Enum.group_by(& &1.vault_id)
    |> Enum.flat_map(fn {vault_id, vault_names} ->
      spelled = Enum.map(vault_names, &{&1, target_spellings(&1.path)})

      pairs = for {name, texts} <- spelled, text <- texts, uniq: true, do: {name.hmac, text}
      candidates = target_candidates(user, vault_id, pairs, dek)

      for {name, texts} <- spelled do
        {name,
         for(
           text <- texts,
           resolve_prefetched(candidates, name.hmac, text) == name.target,
           do: text
         )}
      end
    end)
  end

  defp target_spellings(path) do
    key = basename_key(path)
    bare = [key | Enum.map(@note_exts, &(key <> &1))]

    # The full path and every shorter tail of it that still has a folder
    # (`a/b/note.md` -> `a/b/note.md`, `b/note.md`), each with and without a
    # note extension: a qualified link can name any of them (suffix_match/3).
    segments = path |> String.downcase() |> String.split("/")

    pathed =
      for n <- (length(segments) - 1)..1//-1,
          full = segments |> Enum.take(-(n + 1)) |> Enum.join("/"),
          spelling <- [
            full
            | for(
                ext <- @note_exts,
                String.ends_with?(full, ext),
                do: String.replace_suffix(full, ext, "")
              )
          ],
          do: spelling

    Enum.uniq(bare ++ pathed)
  end

  # One statement, so one snapshot: per name, the edges whose current key
  # names it (top `limit`, by the order the caller picks on); per basename,
  # every edge whose key is missing or stale, which `links_to?/3` decrypts.
  # A concurrent re-extract or backfill cannot make an edge count twice or
  # not at all.
  defp incoming_edges(_user, [], _limit, _distinct?), do: []

  defp incoming_edges(user, names, limit, distinct?) do
    unkeyed =
      for {vault_id, hmac} <-
            Enum.uniq_by(names, &{&1.vault_id, &1.hmac}) |> Enum.map(&{&1.vault_id, &1.hmac}) do
        from(l in NoteLink,
          where:
            l.user_id == ^user.id and l.vault_id == ^vault_id and
              l.target_basename_hmac == ^hmac and
              keys_stale(l.link_keys_stamp, l.target_text_nonce),
          select: map(l, ^@backlink_read_fields)
        )
      end

    keyed =
      for %{vault_id: vault_id, hmac: hmac, keys: keys} <- names, MapSet.size(keys) > 0 do
        keys = MapSet.to_list(keys)

        keyed =
          from(l in NoteLink,
            where:
              l.user_id == ^user.id and l.vault_id == ^vault_id and
                l.target_basename_hmac == ^hmac and l.target_key_hmac in ^keys and
                keys_current(l.link_keys_stamp, l.target_text_nonce),
            limit: ^limit,
            select: map(l, ^@backlink_read_fields)
          )
          |> backlinks_order(distinct?)

        from(k in subquery(keyed), select: map(k, ^@backlink_read_fields))
      end

    (unkeyed ++ keyed)
    |> Enum.reduce(fn part, acc -> union_all(acc, ^part) end)
    |> Repo.all(skip_tenant_check: true)
  end

  # DISTINCT ON collapses a linking note's edges to its first (by position,
  # id); Postgres requires the leading ORDER BY column to match it.
  defp backlinks_order(query, false), do: order_by(query, [l], asc: l.position, asc: l.id)

  defp backlinks_order(query, true) do
    query
    |> distinct([l], l.source_note_id)
    |> order_by([l], asc: l.source_note_id, asc: l.position, asc: l.id)
  end

  # Default: one row per edge, first `limit` by (position, id).
  defp pick_backlinks(sorted, limit, false), do: Enum.take(sorted, limit)

  # One row per linking note (its first edge by position, id), ordered by
  # source id, so `limit + 1` counts distinct linking notes, not link
  # occurrences.
  defp pick_backlinks(sorted, limit, true) do
    sorted
    |> Enum.uniq_by(& &1.source_note_id)
    |> Enum.sort_by(& &1.source_note_id)
    |> Enum.take(limit)
  end

  defp render_backlinks(edges, user, dek) do
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
  # that only updates the struct held *inside* that call; the controller's
  # `current_user` is resolved by auth middleware before the write and never
  # sees it. Such a struct is reloaded fresh (uncached: the `:user` cache entry
  # may predate the DEK). A struct that already carries a wrapped DEK is used as is (on a request
  # path it is the cached `current_user`): `Crypto.get_dek/1` reads the DB's
  # current blob itself on a DekCache miss, so a pre-rotation struct is safe.
  defp reload_for_dek(%{encrypted_dek: blob} = user) when is_binary(blob), do: user
  defp reload_for_dek(%{id: id}), do: Engram.Accounts.get_user!(id)

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
