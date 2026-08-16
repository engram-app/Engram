defmodule Engram.Notes do
  @moduledoc """
  Notes context — CRUD for notes, folders, and tags.
  All operations are tenant-scoped via Repo.with_tenant/2.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.PathCrypto
  alias Engram.Links
  alias Engram.Logger.DecryptFailure
  alias Engram.Logger.Metadata

  alias Engram.Notes.{
    Chunk,
    CrdtBridge,
    CrdtDeliver,
    CrdtPersistence,
    CrdtUpdateLog,
    Enqueue,
    Frontmatter,
    Helpers,
    Note,
    OkfFields,
    PathSanitizer
  }

  alias Engram.Observability.PostHog
  alias Engram.Repo
  alias Engram.Sync.Broadcast
  alias Engram.Telemetry
  alias Engram.UsageMeters

  alias Engram.Workers.{
    DeleteNoteIndex,
    EmbedNote,
    ExtractNoteLinks,
    RebindNoteLinks,
    RewriteNoteLinks
  }

  require Logger

  # Every persisted Note column except content_ciphertext/content_nonce —
  # the metadata projection for reads that never serialize content (changes
  # feeds `fields=meta`, search rehydration). Skipping the big column saves
  # its I/O AND its AES-GCM decrypt (the phase-4 helpers short-circuit
  # per-field on nil ciphertext).
  @note_meta_fields [
    :id,
    :seq,
    :version,
    :kind,
    :dek_version,
    :content_hash,
    :embed_hash,
    :mtime,
    :deleted_at,
    :title_ciphertext,
    :title_nonce,
    :tags_ciphertext,
    :tags_nonce,
    :path_ciphertext,
    :path_nonce,
    :path_hmac,
    :folder_ciphertext,
    :folder_nonce,
    :folder_hmac,
    :tags_hmac,
    :user_id,
    :vault_id,
    :created_at,
    :updated_at,
    :parse_status,
    :parse_reason
  ]

  # Notes resolved per transaction on the change feed. `Repo.with_tenant` takes
  # Ecto's default 15s timeout, and each resolution is a decrypt + Yjs NIF
  # rebuild + tail query + projection — so an unchunked 500-row page of stale
  # notes (what a folder rename produces) could exceed it. A timeout there is
  # not transient: the feed is keyset-ordered, so every retry hits the same page
  # and fails identically — the permanent catch-up wedge the degrade clauses
  # exist to avoid.
  @resolve_chunk 50

  # Delete-wins window: an identical re-push at a path deleted within this many
  # seconds is refused (`:recently_deleted`), so an explicit delete is not
  # silently undone by a stale re-push from another device that still holds the
  # note (the cross-device resurrection race). A byte-different note or a
  # tombstone older than the window is allowed through as a genuine re-create.
  @delete_tombstone_window_seconds 60

  @doc """
  Composable query scope that restricts a `Note` query to kind='note' rows.
  Every site that wants real notes (excluding folder markers) should
  start from `notes_only/0` or include `WHERE kind = 'note'` explicitly.

  The accompanying lint test (`notes_scope_lint_test.exs`) flags raw
  `from(n in Note, ...)` queries that do not include the kind filter.
  """
  @spec notes_only() :: Ecto.Query.t()
  def notes_only do
    from(n in Note, where: n.kind == "note")
  end

  @doc """
  Composable tenant-scope query: `Note` rows owned by `user` in `vault`
  (struct or bare vault id). This predicate IS the multi-tenant isolation
  boundary — note queries must compose from `scoped/2` / `scoped_live/2`;
  `tenant_scope_lint_test.exs` flags hand-inlined `user_id == ^` predicates
  so a dropped clause can't slip in.
  """
  @spec scoped(map(), map() | term()) :: Ecto.Query.t()
  def scoped(user, %{id: vault_id}), do: scoped(user, vault_id)

  def scoped(user, vault_id) do
    from(n in Note, where: n.user_id == ^user.id and n.vault_id == ^vault_id)
  end

  @doc "`scoped/2` plus `is_nil(deleted_at)` — live (non-tombstoned) rows only."
  @spec scoped_live(map(), map() | term()) :: Ecto.Query.t()
  def scoped_live(user, vault) do
    from(n in scoped(user, vault), where: is_nil(n.deleted_at))
  end

  # batch_upsert_notes hard cap: each entry costs an encrypt + CRDT merge, so
  # unbounded requests are a compute-DoS vector, and no client sends >500 (the
  # plugin chunks at ≤100). Delete/move accept ANY size — the seq feed orders
  # by (seq, id) and doesn't care how many rows share a timestamp.
  @max_batch_entries 500

  @doc """
  #590: maps Qdrant point ids → the owning note's decrypted display fields
  (`source_path`, `tags`).

  Search payloads no longer carry plaintext `source_path`/`folder`/`tags`
  (Qdrant Cloud is a separate breach surface). The canonical values live
  only in the encrypted `notes` row, so search rehydrates them here keyed by
  the `chunks.qdrant_point_id → note_id` mapping. Tenant-scoped + decrypted
  as one instrumented batch. Point ids with no live note row are omitted —
  the caller leaves such candidates' display fields untouched.
  """
  @spec display_fields_by_qdrant_points(Engram.Accounts.User.t(), [String.t()]) ::
          %{String.t() => %{source_path: String.t() | nil, tags: [String.t()]}}
  def display_fields_by_qdrant_points(_user, []), do: %{}

  def display_fields_by_qdrant_points(user, qdrant_ids) when is_list(qdrant_ids) do
    uuids =
      for id <- qdrant_ids, is_binary(id), {:ok, u} <- [Ecto.UUID.cast(id)], uniq: true, do: u

    {:ok, pairs} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(c in Chunk,
            join: n in ^notes_only(),
            on: n.id == c.note_id,
            where: c.qdrant_point_id in ^uuids,
            select: {c.qdrant_point_id, struct(n, @note_meta_fields)}
          )
        )
      end)

    {qids, notes} = Enum.unzip(pairs)

    notes
    |> Crypto.decrypt_notes_batch(user)
    |> Enum.zip(qids)
    |> Enum.reduce(%{}, fn
      {{:ok, note}, qid}, acc ->
        Map.put(acc, to_string(qid), %{source_path: note.path, tags: note.tags || []})

      {{:error, _}, _qid}, acc ->
        acc
    end)
  end

  @doc """
  Mints a new note primary key app-side as a v7 UUID string.

  Used at the context boundary so the id is available before INSERT —
  callers stitch it into the AAD bind string (`notes:<col>:<id>`) and the
  `Repo.insert/2` then uses the supplied id verbatim (PK is
  `autogenerate: false` per `Engram.Schema`).

  v7 is time-ordered, so successive mints within the same process sort
  lexically by mint time. That preserves the BTree locality benefits of
  the prior bigserial PK without requiring a server round-trip via
  `nextval()`.
  """
  @spec mint_id() :: Ecto.UUID.t()
  def mint_id, do: UUIDv7.generate()

  @doc """
  Creates an explicit empty-folder marker row (kind="folder").

  Idempotent: if a marker for this folder_hmac already exists, it is
  returned. A soft-deleted marker is undeleted in place (preserves id /
  the AAD-bound envelope). Rejects root folder ("") — root is implicit
  whenever any note exists at the top level.

  The encrypted folder name lives in `folder_ciphertext` / `folder_nonce`
  using the same row-id-bound AAD anchor existing notes already use
  (`row_aad(:notes, :folder, id, dek_version)`). No new crypto surface.
  """
  @spec create_folder_marker(map(), map(), String.t()) ::
          {:ok, Note.t()} | {:error, term()}
  def create_folder_marker(_user, _vault, ""), do: {:error, :root_folder_not_marker}

  def create_folder_marker(user, vault, folder) when is_binary(folder) do
    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      folder_hmac = Crypto.hmac_field(filter_key, folder)

      # Repo.with_tenant wraps the fn return in {:ok, _} (transaction).
      # Unwrap once so the public contract is {:ok, note} | {:error, _}.
      case Repo.with_tenant(user.id, fn ->
             case find_folder_marker(user, vault, folder_hmac) do
               {:ok, %Note{deleted_at: nil} = existing} ->
                 {:ok, hydrate_folder_marker(existing, dek)}

               {:ok, %Note{} = soft_deleted} ->
                 soft_deleted
                 |> Ecto.Changeset.change(deleted_at: nil, updated_at: DateTime.utc_now())
                 |> Ecto.Changeset.put_change(:seq, Engram.Vaults.next_seq!(vault.id))
                 |> Repo.update()
                 |> case do
                   {:ok, undeleted} -> {:ok, hydrate_folder_marker(undeleted, dek)}
                   {:error, _} = err -> err
                 end

               :not_found ->
                 insert_folder_marker(user, vault, dek, folder, folder_hmac)
             end
           end) do
        {:ok, inner} -> inner
        {:error, _} = err -> err
      end
    end
  end

  # Folder marker rows have only folder_* ciphertext populated, so
  # Crypto.maybe_decrypt_note_fields/2 short-circuits (needs path or
  # content present). Decrypt the folder field directly here.
  defp hydrate_folder_marker(%Note{} = marker, dek) do
    folder_aad = row_aad(:notes, :folder, marker.id, marker.dek_version)

    case Envelope.decrypt(marker.folder_ciphertext, marker.folder_nonce, dek, folder_aad) do
      {:ok, folder} -> %{marker | folder: folder}
      :error -> raise "failed to decrypt folder marker id=#{marker.id}"
    end
  end

  defp find_folder_marker(user, vault, folder_hmac) do
    row =
      Repo.one(
        from(n in scoped(user, vault),
          where: n.kind == "folder" and n.folder_hmac == ^folder_hmac
        )
      )

    if row, do: {:ok, row}, else: :not_found
  end

  defp insert_folder_marker(user, vault, dek, folder, folder_hmac) do
    marker_id = mint_id()
    now = DateTime.utc_now()
    folder_aad = Crypto.aad_for_row(:notes, :folder, marker_id)
    {folder_ct, folder_nonce} = Envelope.encrypt(folder, dek, folder_aad)

    attrs = %{
      kind: "folder",
      user_id: user.id,
      vault_id: vault.id,
      version: 1,
      dek_version: Crypto.row_version_aad_bound(),
      mtime: DateTime.to_unix(now) + 0.0,
      folder_ciphertext: folder_ct,
      folder_nonce: folder_nonce,
      folder_hmac: folder_hmac
    }

    changeset =
      %Note{id: marker_id}
      |> Note.changeset(attrs)
      |> Ecto.Changeset.put_change(:seq, Engram.Vaults.next_seq!(vault.id))

    # INSERT ... ON CONFLICT DO NOTHING on the folder-marker partial unique
    # index. A concurrent create of the same folder races us: find_folder_marker
    # saw :not_found, then this insert collides on `notes_user_vault_folder_marker`.
    # A bare insert would raise a unique violation that aborts the WHOLE enclosing
    # Repo.with_tenant transaction — its trailing role-reset query then 25P02s and
    # the caller 500s. ON CONFLICT DO NOTHING no-ops the loser's insert at the SQL
    # level instead, leaving the transaction healthy. Folder creation is
    # idempotent, so we collapse to whichever live marker now occupies the path
    # (ours if we won, the winner's otherwise). The index is partial
    # (WHERE deleted_at IS NULL), so the occupant is always a LIVE marker; match
    # deleted_at: nil explicitly to stay correct even if find_folder_marker (no
    # deleted_at filter) ever returns a tombstone. No conflict_target — the only
    # unique index a kind="folder" row can violate is notes_user_vault_folder_marker;
    # a bare DO NOTHING (as the insert_all sites elsewhere do) sidesteps the
    # partial-index conflict_target fragment-matching footgun.
    case Repo.insert(changeset, on_conflict: :nothing) do
      {:ok, _} ->
        case find_folder_marker(user, vault, folder_hmac) do
          {:ok, %Note{deleted_at: nil} = marker} ->
            {:ok, hydrate_folder_marker(marker, dek)}

          _ ->
            {:error, Ecto.Changeset.add_error(changeset, :folder, "insert raced and vanished")}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Soft-deletes an explicit folder marker. Has no effect on real notes
  living under the same folder path — those continue to derive the
  folder in `list_folders_with_counts/2`.

  Returns `{:ok, :deleted}` when a marker was found and removed, or
  `{:ok, :not_found}` for idempotent no-op. The controller surfaces 204
  in both cases.
  """
  @spec delete_folder_marker(map(), map(), String.t()) ::
          {:ok, :deleted | :not_found} | {:error, term()}
  def delete_folder_marker(user, vault, folder) when is_binary(folder) do
    with {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      folder_hmac = Crypto.hmac_field(filter_key, folder)

      # Repo.with_tenant wraps the fn return in {:ok, _} (transaction).
      # Unwrap once so the public contract is {:ok, :deleted | :not_found} | {:error, _}.
      case Repo.with_tenant(user.id, fn ->
             case find_folder_marker(user, vault, folder_hmac) do
               {:ok, %Note{deleted_at: nil} = marker} ->
                 marker
                 |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
                 |> Ecto.Changeset.put_change(:seq, Engram.Vaults.next_seq!(vault.id))
                 |> Repo.update()
                 |> case do
                   {:ok, _} -> {:ok, :deleted}
                   {:error, _} = err -> err
                 end

               {:ok, _already_soft_deleted} ->
                 {:ok, :not_found}

               :not_found ->
                 {:ok, :not_found}
             end
           end) do
        {:ok, inner} -> inner
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Creates or updates a note. Sanitizes path, extracts metadata, computes content_hash.
  Returns {:ok, note} or {:error, changeset}.

  Options:

    * `broadcast_from: pid` — emit the `note_changed` broadcast via
      `Endpoint.broadcast_from/4` so the given subscriber (the pushing
      channel process) is excluded. Channel pushes pass `self()`; HTTP
      pushes have no socket to exclude and use plain broadcast.
  """
  @spec upsert_note(map(), map(), map(), keyword()) ::
          {:ok, Note.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :version_conflict, Note.t()}
          | {:error, {:notes_cap_reached, non_neg_integer(), non_neg_integer()}}
          | {:error, atom()}
  def upsert_note(user, vault, attrs, opts \\ []) do
    path = attrs["path"] || attrs[:path]
    # Scrub invalid UTF-8 before it is hashed/encrypted/stored: content is kept
    # as `bytea` ciphertext (no Postgres UTF-8 guard), and stray bytes later
    # crash Jason at every JSON boundary (search, sync Channel). Valid content
    # is unchanged, so the content_hash is stable for the common case.
    content = (attrs["content"] || attrs[:content] || "") |> Helpers.scrub_utf8(:write)
    mtime = attrs["mtime"] || attrs[:mtime]
    client_id = attrs["id"] || attrs[:id]

    opts = put_base_hash_opt(opts, attrs)

    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, path} <- validate_path(path),
         {:ok, hash} <- content_hash(user, content) do
      sanitized_path = PathSanitizer.sanitize(path)
      title = Helpers.extract_title(content, sanitized_path)
      folder = Helpers.extract_folder(sanitized_path)
      tags = Helpers.extract_tags(content)
      now = DateTime.utc_now()

      base_attrs = %{
        # Belt-and-suspenders: schema default is "note", but stamping it
        # explicitly here keeps the kind invariant intact even if a future
        # caller bypasses the default (e.g., raw insert_all). The partial
        # unique indexes split by kind, so this is what lets a real note
        # coexist with a folder marker at the same path string.
        kind: "note",
        content: content,
        title: title,
        tags: tags,
        content_hash: hash,
        mtime: mtime,
        user_id: user.id,
        vault_id: vault.id,
        created_at: now,
        updated_at: now
      }

      {:ok, lookup_query} = note_by_path_query(user, vault, sanitized_path)

      result =
        Repo.with_tenant(user.id, fn ->
          lookup_and_write(
            %{
              query: lookup_query,
              client_id: client_id,
              vault: vault,
              base: base_attrs,
              user: user,
              path: sanitized_path,
              folder: folder,
              tags: tags,
              opts: opts
            },
            1
          )
        end)

      case result do
        {:ok, {:ok, {prev_hash, note, _merged_text, _content_hash}}} ->
          _ =
            if prev_hash != note.content_hash do
              _ = Enqueue.enqueue(EmbedNote.new_debounced(note.id), "embed_note")
              # #648 lever 1 — cheap edge extraction must not ride the embed
              # debounce (30s) or the embed budget gate; ~2s leading edge.
              Enqueue.enqueue(ExtractNoteLinks.new_debounced(note.id), "extract_note_links")
            end

          note = decrypt_or_raise!(note, user)
          maybe_log_path_rewrite(user, vault, path, sanitized_path, note.id)

          # Hash equality means do_update_note short-circuited (no version/seq
          # change persisted) — broadcasting would fan a phantom change out to
          # every connected device. Inserts (prev_hash nil) and real updates
          # always differ, so they broadcast as before; forced rewrites may
          # keep the same hash (e.g. a tags repair) but did persist a change.
          _ =
            if prev_hash != note.content_hash or Keyword.get(opts, :force, false) do
              :ok = broadcast_change(user.id, vault.id, "upsert", note.path, note, opts)
            end

          if is_nil(prev_hash) do
            # A brand-new note may be the exact target a dangling link (or an
            # existing binding losing the shortest-path tiebreak) has been
            # waiting on — re-resolve every edge sharing its basename (#591).
            _ =
              Enqueue.enqueue(
                RebindNoteLinks.new_for(
                  user.id,
                  vault.id,
                  Links.basename_hmac(user, Links.basename_key(note.path))
                ),
                "rebind_note_links"
              )

            # FTUX vault page listens for this — fires when an empty vault
            # gets its first note (typical case: Obsidian plugin completes
            # its first sync push).
            maybe_broadcast_vault_populated(user, vault)

            # Funnel telemetry — emit once per real creation so the funnel
            # doesn't double-count idempotent re-pushes of unchanged notes.
            :ok =
              PostHog.capture(
                PostHog.distinct_id_for(user),
                "note_created",
                %{vault_id: vault.id}
              )
          end

          {:ok, note}

        {:ok, {:ok, {:moved, prev_hash, note, _merged_text, _content_hash}}} ->
          # An id-keyed rename moved an existing row to a new path (move_note).
          # Re-embed only when the content actually changed (a pure rename keeps
          # the same hash), but ALWAYS broadcast: the move persisted a real
          # change (path/seq/version), and skipping the broadcast on hash
          # equality would strand peers with the old-path delete and no
          # new-path upsert until they next pull.
          _ =
            if prev_hash != note.content_hash do
              _ = Enqueue.enqueue(EmbedNote.new_debounced(note.id), "embed_note")
              # #648 lever 1 — cheap edge extraction must not ride the embed
              # debounce (30s) or the embed budget gate; ~2s leading edge.
              Enqueue.enqueue(ExtractNoteLinks.new_debounced(note.id), "extract_note_links")
            end

          note = decrypt_or_raise!(note, user)
          maybe_log_path_rewrite(user, vault, path, sanitized_path, note.id)
          :ok = broadcast_change(user.id, vault.id, "upsert", note.path, note, opts)
          {:ok, note}

        {:ok, {:conflict, existing}} ->
          # Concurrent-insert race: two clients both saw nil on the lookup and
          # both tried to INSERT the same new path. The loser's ON CONFLICT DO
          # NOTHING no-ops the insert; we re-fetch and find the winner's row
          # instead of our own id. Log server-side so the race is detectable in
          # triage, then return the existing note so the caller (channel / REST
          # controller) can hand back a 409 that the client reconciles.
          Logger.warning(
            "note_concurrent_insert_race",
            Metadata.with_category(:warning, :sync,
              user_id: user.id,
              vault_id: vault.id,
              note_id: existing.id,
              server_version: existing.version
            )
          )

          # Phase B.3: virtual path/folder/tags need to be populated from
          # ciphertext before the controller serializes the conflict response.
          {:error, :version_conflict, decrypt_or_raise!(existing, user)}

        {:ok, {:stale_base, existing}} ->
          # Phase 0 stale-base gate: the writer declared a base_hash the row no
          # longer holds. Refused to merge (a stale full-content push deletes
          # newer content convergently — 2026-07-07 reconnect clobber). Distinct
          # greppable key so the rate is monitorable in Loki.
          Logger.warning(
            "note_stale_base_rejected",
            Metadata.with_category(:warning, :sync,
              user_id: user.id,
              vault_id: vault.id,
              note_id: existing.id,
              server_version: existing.version
            )
          )

          {:error, :version_conflict, decrypt_or_raise!(existing, user)}

        {:ok, {:id_collision, live}} ->
          # A push carried a note_id that already names a LIVE note at another
          # path. Refused to move/merge (that destroys the live note). Log with
          # a distinct, greppable key so this class — invisible until the
          # 2026-07-06 corruption incident — is monitorable in Loki, then hand
          # back a conflict so the client reconciles (re-mints its id / pulls).
          Logger.warning(
            "note_id_collision_rejected",
            Metadata.with_category(:warning, :sync,
              user_id: user.id,
              vault_id: vault.id,
              note_id: live.id,
              server_version: live.version
            )
          )

          {:error, :version_conflict, decrypt_or_raise!(live, user)}

        {:ok, {:error, changeset}} ->
          {:error, changeset}

        {:error, _} = err ->
          err
      end
    end
  end

  defp insert_new_note(base_attrs, user, sanitized_path, folder, _tags, client_id, lookup_query) do
    # Pricing v2 §G — server-side notes_cap enforcement. Free tier defaults
    # to 10k notes; Starter to 50k; Pro unlimited. Resolver returns nil for
    # the unlimited case, in which check_limit is a no-op. The current count is
    # a maintained counter (usage_meters.notes_count), not a per-insert
    # COUNT(*); we increment it inside this tenant transaction so it stays
    # atomic with the INSERT.
    #
    # The check itself is best-effort, not a hard guarantee: read-then-insert
    # is non-atomic, so concurrent inserts can land slightly over the cap. This
    # matches the COUNT(*) approach it replaced (same TOCTOU window) and is fine
    # for a soft abuse-deterrent cap. A hard cap would need a conditional
    # UPDATE ... WHERE notes_count < limit gating the insert.
    current_count = UsageMeters.notes_count(user.id)

    cond do
      recently_deleted_twin?(user, base_attrs.vault_id, sanitized_path, base_attrs.content_hash) ->
        # Delete-wins race: this is a fresh create (no live path match, no
        # client-id match) at a path an explicit delete tombstoned seconds ago,
        # carrying identical content — i.e. another device re-pushing the note
        # it still holds. Refuse so the delete stands; the client converges by
        # dropping its local copy. Resurrect-by-id (rename restore) never
        # reaches here — it takes move_note's branch on a client-id match.
        {:error, :recently_deleted}

      match?({:error, :limit_reached}, Billing.check_limit(user, :notes_cap, current_count)) ->
        # Free-tier launch §4.5 — carry the resolved limit + current count
        # back to the controller so the 402 body can populate them. The
        # resolver call here is the same one check_limit already made
        # internally; a second call is cheaper than threading the value out
        # of check_limit (no hot path).
        limit = Billing.effective_limit(user, :notes_cap)
        {:error, {:notes_cap_reached, limit, current_count}}

      true ->
        # T3.6 — pre-allocate the row id so the AAD bind string
        # ("notes:<column>:<id>") can be computed before INSERT. As of the
        # PG18 + UUIDv7 rework (Phase B), the id is minted app-side via
        # `mint_id/0` (v7 uuid) instead of pulled from a bigserial sequence.
        # Phase I — accept a client-supplied uuid so the plugin / SDK can
        # mint offline and push under a stable id. Falls back to server mint
        # when nil or malformed.
        note_id =
          case client_id && Ecto.UUID.cast(client_id) do
            {:ok, valid_uuid} -> valid_uuid
            _ -> mint_id()
          end

        case do_bare_insert(base_attrs, user, sanitized_path, folder, note_id, lookup_query) do
          {:inserted, inserted, crdt} ->
            {:ok, {nil, inserted, crdt.merged_text, crdt.content_hash}}

          {:raced, existing} ->
            # Concurrent create won; report a version conflict (→ 409) the client
            # reconciles, exactly like a stale-version write.
            {:conflict, existing}

          {:error, _} = err ->
            err
        end
    end
  end

  # Shared create leg for a brand-new note row at a brand-new path, used by both
  # insert_new_note/7 (REST/MCP/web) and genesis_insert_bare/6 (crdt_create).
  # crdt merge → encrypt → phase_b/okf/parse_status → seq → INSERT ON CONFLICT
  # DO NOTHING → re-fetch. The two callers differ ONLY in what they map the
  # neutral result to (REST returns a raw 4-tuple + {:conflict, _}; genesis
  # decrypts inline + tags :announce / :version_conflict), so this returns a
  # caller-agnostic result and each maps it to its own contract:
  #   {:inserted, %Note{}, crdt_map} — our row won; counter already bumped
  #   {:raced, %Note{}}              — a concurrent create won the path
  #   {:error, Changeset.t()}        — validation/insert error (or a bare
  #                                     {:error, term} from merge/encrypt)
  #
  # INSERT ... ON CONFLICT DO NOTHING on the live-note partial unique index: a
  # concurrent upsert of the same new path raced us — both saw `nil` on the
  # lookup, so both reach here. A bare insert would raise a
  # notes_user_vault_path_v2 unique violation that aborts the whole tenant
  # transaction (its trailing role-reset query then 25P02s → controller 500),
  # and the plugin's offline-queue flush treats a 500 as fatal (breaks the
  # drain, flips offline) — the test_24 replay flake. ON CONFLICT DO NOTHING
  # no-ops the loser's insert at the SQL level instead, leaving the transaction
  # healthy. We then re-fetch and compare ids to tell winner (we inserted our
  # row) from loser (someone else's row now occupies the path). No
  # conflict_target — the only unique index a kind="note" row can violate is
  # notes_user_vault_path_v2; a bare DO NOTHING (matching the insert_all sites
  # elsewhere in this module) sidesteps the partial-index conflict_target
  # fragment-matching footgun.
  #
  # ...but notes_user_vault_path_v2 is NOT the only unique index a row can
  # violate: the PRIMARY KEY on `id` is one too, and it is GLOBAL while every
  # lookup here is vault-scoped. A client that pushes a note id already owned by
  # another vault (copy a vault, keep its ids, sync into a fresh one) therefore
  # took this route: classify_by_id scopes to the vault and says :none → the path
  # lookup says nil → INSERT hits the PK → DO NOTHING swallows it → the re-fetch
  # (path-keyed, vault-scoped) finds nothing → "insert raced and vanished" → a
  # generic create_failed the client retries forever under the SAME colliding id.
  # The note was dropped, silently and permanently.
  #
  # So `nil` here means "our insert no-op'd AND no live row owns this path" —
  # the conflict was on the id, not the path. remint_own_id/7 decides from there;
  # see its comment for which collisions re-mint and which still 422. When it does
  # re-mint it recurses ONCE (`remint?` bounds it; a fresh v7 uuid cannot collide
  # again), and the row returns through the normal success path, so the real id
  # reaches the client in the crdt_create ack's doc_id / the REST body and the
  # plugin's existing ADOPT path remaps the note to it (sync.ts
  # applyCrdtCreateAck + pushFile's live adopt).
  #
  # Fixing it HERE rather than replying a new error reason is deliberate: this leg
  # is shared by REST/MCP/web and crdt_create, and re-minting also repairs
  # already-released plugins, which a new reason code could not.
  defp do_bare_insert(
         base_attrs,
         user,
         sanitized_path,
         folder,
         note_id,
         lookup_query,
         remint? \\ true
       ) do
    with {:ok, crdt} <- maybe_merge_crdt(nil, base_attrs.content, user, note_id),
         merged_attrs = %{
           base_attrs
           | content: crdt.merged_text,
             title: Helpers.extract_title(crdt.merged_text, sanitized_path),
             tags: crdt.tags,
             content_hash: crdt.content_hash
         },
         {:ok, encrypted} <- Crypto.encrypt_note_fields(merged_attrs, user, note_id) do
      phase_b =
        inject_phase_b_fields(encrypted, user, note_id, sanitized_path, folder, crdt.tags)
        |> inject_okf_fields(user, note_id, crdt.merged_text)
        |> put_parse_status(crdt.merged_text)
        |> Map.put(:crdt_state_ciphertext, crdt.crdt_state_ciphertext)
        |> Map.put(:crdt_state_nonce, crdt.crdt_state_nonce)

      changeset = Note.changeset(%Note{id: note_id}, phase_b)

      seq = Engram.Vaults.next_seq!(base_attrs.vault_id)
      changeset = Ecto.Changeset.put_change(changeset, :seq, seq)

      case Repo.insert(changeset, on_conflict: :nothing) do
        {:ok, _} ->
          case Repo.one(lookup_query) do
            %Note{id: ^note_id} = inserted ->
              :ok = UsageMeters.inc_notes_count(user.id, 1)
              {:inserted, inserted, crdt}

            %Note{} = existing ->
              {:raced, existing}

            nil when remint? ->
              remint_own_id(
                base_attrs,
                user,
                sanitized_path,
                folder,
                note_id,
                lookup_query,
                changeset
              )

            nil ->
              {:error, Ecto.Changeset.add_error(changeset, :path, "insert raced and vanished")}
          end

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # Reached only when the INSERT no-op'd AND no live row owns the path, i.e. the
  # conflict was on the id. Whose id decides what happens, and RLS answers that
  # for free: this connection is scoped to the CURRENT USER, and the lookups that
  # already failed were scoped to the current VAULT. So a row visible to this
  # unvaulted query is the same user's, in one of their OTHER vaults; a row that
  # stays invisible belongs to somebody else.
  #
  #   * Visible, so theirs -> re-mint and retry once. The headline case is the
  #     vault copy (their own note, a new vault, a new identity); returning an
  #     error here is what silently dropped 304 notes.
  #   * Invisible, so someone else's -> keep the 422. Deliberate cross-tenant
  #     guard, asserted by notes_controller_test "rejects a client-supplied id
  #     colliding with another user's note": a caller must not be able to probe
  #     or adopt another tenant's PK, and quietly minting them a row on the back
  #     of a hijack attempt is not a favour worth doing.
  #
  # The probe filters on NOTHING but the id, and that is deliberate on both axes.
  # It does not filter `kind`, because an attachment or folder-marker row of
  # theirs occupies the PK just as hard as a note does (the id space is shared)
  # and the note still has to land; classify_by_id's `kind == "note"` scope is
  # why such a row reaches here as :none in the first place. It does not filter
  # `deleted_at` either, because a tombstone still owns the PK.
  #
  # So the tripwire says "already taken", not "owned by another vault": a
  # same-vault attachment collision and a genuine vanished-race (the winning row
  # tombstoned between our INSERT and the live-only re-fetch) both land here and
  # both re-mint. That is the right outcome for all three -- the caller's note
  # lands under an id nobody owns -- but do not read a spike as proof that
  # clients are pushing foreign vault ids.
  # One message for both re-mint sites (classify_by_id's early :taken route and
  # remint_own_id's post-INSERT backstop) so a single Loki query covers the whole
  # class. Deliberately does not name a cause: see remint_own_id for the three
  # different collisions that can land here.
  defp log_id_taken(user, vault_id, old_id, new_id) do
    Logger.warning(
      "note id already taken; re-minting #{old_id} -> #{new_id}",
      Metadata.with_category(:warning, :sync,
        user_id: user.id,
        vault_id: vault_id,
        note_id: old_id,
        reminted_to: new_id
      )
    )
  end

  defp remint_own_id(
         base_attrs,
         user,
         sanitized_path,
         folder,
         note_id,
         lookup_query,
         changeset
       ) do
    if Repo.exists?(from(n in Note, where: n.id == ^note_id)) do
      fresh_id = mint_id()

      log_id_taken(user, base_attrs.vault_id, note_id, fresh_id)

      do_bare_insert(base_attrs, user, sanitized_path, folder, fresh_id, lookup_query, false)
    else
      {:error, Ecto.Changeset.add_error(changeset, :path, "insert raced and vanished")}
    end
  end

  @doc """
  Create/resurrect/adopt a BARE note row for a client-minted id over CRDT
  (crdt_create). Content is owned by the CRDT room and arrives via crdt_msg —
  this never merges empty content against an existing row and never content-
  broadcasts. See docs spec 2026-07-15-crdt-create-genesis-bare-row-design.
  """
  @spec genesis_crdt_note(map(), map(), String.t(), String.t(), keyword()) ::
          {:ok, Note.t()}
          | {:adopted, Note.t()}
          | {:error, :invalid_id}
          | {:error, :recently_deleted}
          | {:error, :id_conflict, Note.t()}
          | {:error, :version_conflict, Note.t()}
          | {:error, {:notes_cap_reached, non_neg_integer(), non_neg_integer()}}
          | {:error, Ecto.Changeset.t()}
          # Crypto/KMS failure class (Crypto.ensure_user_dek / encrypt_note_fields
          # / maybe_merge_crdt / dek_filter_key can each return a bare
          # {:error, term}). Kept in the spec so the channel's create_failed
          # catch-all is reachable, not flagged unreachable by dialyzer.
          | {:error, term()}
  def genesis_crdt_note(user, vault, id, path, opts \\ []) do
    origin = Keyword.get(opts, :origin)

    with {:ok, canonical_id} <- Ecto.UUID.cast(id),
         {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, path} <- validate_path(path) do
      sanitized_path = PathSanitizer.sanitize(path)
      folder = Helpers.extract_folder(sanitized_path)

      # Repo.with_tenant wraps the fn return in {:ok, _} (transaction).
      # Unwrap once so the public contract matches the @spec above.
      case Repo.with_tenant(user.id, fn ->
             case classify_by_id(vault, canonical_id) do
               {:live, %Note{} = live} ->
                 # A dek_filter_key failure here must NOT masquerade as a definite
                 # id_conflict (a transient crypto hiccup would permanently reject
                 # an idempotent retry): {:ok, true} idempotent, {:ok, false}
                 # genuine conflict, {:error, _} a clean crypto error (→
                 # create_failed) — never a fabricated conflict.
                 case same_path?(live, user, sanitized_path) do
                   {:ok, true} ->
                     {:ok, decrypt_or_raise!(live, user)}

                   {:ok, false} ->
                     # Phase E2 (rename-as-move): a crdt_create for a KNOWN live
                     # id at a new, FREE path is a rename — relocate the row in
                     # place (same move_note pipeline the tombstone-resurrect
                     # rename leg uses), no tombstone-first dance, which also
                     # removes the #970 delete-wins window from renames entirely.
                     # A target path OCCUPIED by a DIFFERENT live note stays a
                     # genuine conflict (the pre-E2 behavior).
                     genesis_relocate_live(live, user, vault, sanitized_path, folder, origin)

                   {:error, _} = err ->
                     err
                 end

               {:tombstone, %Note{} = prior} ->
                 genesis_resurrect(prior, user, vault, sanitized_path, folder, origin)

               :taken ->
                 # The id is already spoken for by a row of theirs that this
                 # vault's genesis cannot use, so an INSERT under it is doomed:
                 # it would no-op on the PK and be recovered by remint_own_id one
                 # layer down, AFTER burning a crdt merge, an encrypt (KMS/DEK
                 # work) and a permanently-consumed vault seq. Re-mint here, where
                 # classify_by_id has already paid for the read that proves it.
                 # An OCCUPIED path still adopts the note living there, exactly
                 # like :none, so the fresh id is only reached on the insert leg.
                 genesis_adopt_or_insert(
                   user,
                   vault,
                   mint_id(),
                   sanitized_path,
                   folder,
                   canonical_id
                 )

               :none ->
                 genesis_adopt_or_insert(user, vault, canonical_id, sanitized_path, folder)
             end
           end) do
        # Only genesis_resurrect/genesis_insert_bare tag their success with
        # :announce (a REAL create/resurrect). The idempotent same-path and
        # adopt-existing-live-note branches change nothing, so they return a
        # plain {:ok, note} and fall through to the catch-all below — no
        # announce. Fired post-commit (outside the transaction fn, after
        # Repo.with_tenant returns) so a client that pulls on crdt_doc_ready
        # never races the row's own commit — same discipline as the other
        # CrdtDeliver call sites in this module.
        {:ok, {:ok, note, :announce}} ->
          :ok = CrdtDeliver.announce_ready(user.id, vault.id, note.path, note.id)

          # The web /link success page waits on this before forwarding the user
          # to their vault. It used to fire only from the REST upsert/batch
          # paths — which the Obsidian plugin stopped using when it moved to
          # CRDT — so an Obsidian first sync, the exact case that page exists
          # for, never advanced. Same post-commit position as the announce
          # above; the helper's own 0->1 probe keeps it to the first note.
          :ok = maybe_broadcast_vault_populated(user, vault)
          {:ok, note}

        {:ok, {:ok, note, {:announce_moved, old_path}}} ->
          # A rename-as-move (live relocate or resurrect-rename) must fan BOTH the
          # new-path upsert AND the old-path delete to peers — exactly like the
          # REST rename delete leg (do_rewrite_note). broadcast_change's "upsert"
          # also deliver_outs the CRDT state (announces the doc), so no separate
          # announce_ready is needed. Upsert BEFORE delete: a receiver relocates
          # the note's id to the new path first, so it treats the delete as a
          # relocation leg (id now lives elsewhere) instead of tearing the note's
          # CRDT room down by id. Without the old-path delete a web receiver (no
          # local mirror) keeps the note in its old folder forever. Fired
          # post-commit, same as the :announce leg above.
          :ok = broadcast_change(user.id, vault.id, "upsert", note.path, note, [])

          if old_path != note.path do
            :ok = broadcast_change(user.id, vault.id, "delete", old_path, note.id, [])
          end

          {:ok, note}

        {:ok, {:ok, note, :adopted}} ->
          # Surfaced, not flattened to {:ok, note}: the batch create leg has to
          # tell "we made this row" from "a different note already owned the
          # path", because only the former means the caller's frame was applied.
          {:adopted, note}

        {:ok, inner} ->
          inner

        {:error, _} = err ->
          err
      end
    else
      :error -> {:error, :invalid_id}
      {:error, _} = err -> err
    end
  end

  # :none-branch of genesis_crdt_note/4: no row by client id, so route by PATH.
  # note_by_path_query is computed HERE (its only consumer), not at the top of
  # the txn — the :live / :tombstone branches never touch it, so hoisting it
  # wasted a dek_filter_key + hmac on every call AND hard-matched {:ok, _} = ...,
  # so a filter-key error crashed the channel with a MatchError. Handling the
  # error cleanly turns it into a create_failed reply (via the channel catch-all).
  # Runs inside the caller's Repo.with_tenant txn (tenant-scoped reads/writes).
  #
  # `taken_id` is the id the CLIENT sent when classify_by_id found it already
  # spoken for and the caller substituted a fresh mint, and nil otherwise. It
  # exists only so the re-mint is logged on the leg that actually inserts: an
  # OCCUPIED path adopts the note living there and never uses the fresh id, so
  # announcing a re-mint up at the call site would cry wolf on every adopt.
  defp genesis_adopt_or_insert(user, vault, canonical_id, sanitized_path, folder, taken_id \\ nil) do
    case note_by_path_query(user, vault, sanitized_path) do
      {:ok, lookup_query} ->
        case Repo.one(lookup_query) do
          %Note{} = live ->
            # ADOPTED, not created: the path is already owned by a live note under
            # a DIFFERENT id, and this caller's content frame was never applied to
            # it. Tagged so the batch leg can say so instead of reporting a create
            # (see crdt_channel prepare_create/4) -- a plain {:ok, note} here reads
            # as success and silently discards the client's body.
            {:ok, decrypt_or_raise!(live, user), :adopted}

          nil ->
            # Logged AFTER the insert lands, not before: genesis_insert_bare can
            # still fail on the notes cap or a changeset, and a tripwire naming a
            # reminted_to id that never existed makes the Loki count lie.
            case genesis_insert_bare(
                   user,
                   vault,
                   canonical_id,
                   sanitized_path,
                   folder,
                   lookup_query
                 ) do
              {:ok, _note, _tag} = ok ->
                if taken_id, do: log_id_taken(user, vault.id, taken_id, canonical_id)
                ok

              other ->
                other
            end
        end

      {:error, _} = err ->
        err
    end
  end

  # Classifies a client-supplied note id against this vault:
  #
  #   {:live, note}      a live note of THIS vault — same-path is a no-op
  #                      re-genesis, different-path is a rename or a collision
  #   {:tombstone, note} a soft-deleted note of this vault — routes to resurrect
  #   :taken             a row of THEIRS the id is already spoken for by, but
  #                      not one this vault's genesis can use: another of their
  #                      vaults (the vault-copy case) or another `kind` in this
  #                      one (the id space is shared with attachments and folder
  #                      markers). The PK is occupied, so genesis must re-mint.
  #   :none              no row at all, anywhere this connection can see. RLS
  #                      scopes it to the current user, so another USER's row
  #                      reads as :none and stays that way (see remint_own_id).
  #
  # This inlines the Repo.get that existing_by_client_id/2 does rather than
  # wrapping it, because that helper collapses :taken and :none into one `nil`
  # by filtering on vault + kind, and :taken is exactly what lets genesis skip
  # a doomed INSERT. It is the SAME single read either way, not an extra one.
  # existing_by_client_id/2 stays as-is for upsert_pathless's legacy REST
  # branching, which only needs the row-or-nil answer.
  defp classify_by_id(vault, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Note{} = row <- Repo.get(Note, uuid) do
      case row do
        %Note{vault_id: vid, kind: "note", deleted_at: nil} = live when vid == vault.id ->
          {:live, live}

        %Note{vault_id: vid, kind: "note"} = tombstone when vid == vault.id ->
          {:tombstone, tombstone}

        %Note{} ->
          :taken
      end
    else
      _ -> :none
    end
  end

  # `note.path` is a virtual field (real path lives encrypted in
  # path_ciphertext, indexed via path_hmac) — it's unset on a row fetched by
  # id that hasn't been through decrypt_or_raise!/2 yet, so a raw `==` against
  # it silently always mismatches. Compare path_hmac instead, same pattern as
  # recent_same_path_tombstone?/3. Returns {:ok, boolean} on a clean compare and
  # {:error, reason} when the filter key can't be derived — so the caller can
  # tell "definitely a different path" ({:ok, false} → id_conflict) apart from
  # "couldn't tell" ({:error, _} → create_failed). Collapsing a crypto error to
  # `false` here permanently rejected an idempotent retry as a spurious conflict.
  defp same_path?(%Note{} = note, user, sanitized_path) do
    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} -> {:ok, note.path_hmac == Crypto.hmac_field(filter_key, sanitized_path)}
      {:error, _} = err -> err
    end
  end

  # Resurrects a tombstone found by client id: reuses move_note's re-path +
  # deleted_at-clear + version/seq-bump pipeline, but feeds it the tombstone's
  # OWN decrypted content as the "incoming" content. move_note's crdt merge
  # (maybe_merge_crdt) diffs incoming content against the prior CRDT snapshot
  # — incoming == prior's own content is therefore a content-against-itself
  # identity merge (no-op diff), never the empty-string wipe that bit earlier
  # crdt_create attempts (feeding "" as incoming merges empty over the note).
  #
  # base_attrs must carry `title`/`tags`/`content_hash` keys (not just
  # `content`) because move_note rebuilds merged_attrs via the `%{base_attrs |
  # ...}` update syntax, which requires every replaced key to already exist —
  # sourcing them from `prior` also preserves them in case the merge is ever
  # a genuine no-op (mtime included for the same reason: don't regress it to
  # nil on resurrect).
  #
  # No notes_cap gate here (round-2 review, reverting round-1 FIX 4): REST's
  # resurrect path (upsert_pathless -> move_note) has no cap check either —
  # resurrecting your OWN tombstone is self-recovery, not new creation. Only
  # the genuinely-new-row leg (genesis_insert_bare) caps.
  #
  # Uses the non-raising Crypto.maybe_decrypt_note_fields/2 (not
  # decrypt_or_raise!/2): a DEK/KMS decrypt failure on the tombstone's
  # ciphertext must surface as a clean {:error, _} that the channel replies
  # create_failed for, not a raise that crashes/drops the socket.
  # Phase E2 (rename-as-move): relocate a LIVE note to a new FREE path when its
  # own id arrives via crdt_create at that path — the socket-native rename.
  # Mirrors genesis_resurrect_decrypted's move leg (identity content merge via
  # move_note: re-path + version/seq bump + :announce_moved fan-out) minus the
  # tombstone concerns. An occupied target keeps the pre-E2 id_conflict reply,
  # with the same greppable Loki tripwire as REST's upsert {:id_collision, live}
  # arm (a client-minted id reused at another OCCUPIED path is still the
  # 2026-07-06 wrong-mint corruption signature).
  # ── Phase 2 (#648/#1231) — CRDT-origin rename rewrite gate ─────────────────
  #
  # FLIPPED to "web" 2026-08-07 (#1301). The prior "obsidian" value was a
  # deliberate skew compromise: while plugins predating the client_type join
  # tag (< 1.20.0) were the majority, treating an untagged socket as
  # plugin-origin kept Obsidian the sole rewriter. Flipping early would have
  # had BOTH sides rewrite the same wikilinks — concurrent positional edits in
  # one Y-doc, which is exactly what the one-rewriter invariant exists to
  # prevent.
  #
  # "web" is the spec's safe default and is now the correct one: any NON-
  # Obsidian client that omits the tag (an old web build, a future mobile
  # client) previously got no rewrite at all and silently rotted links with no
  # error surface. Obsidian still opts out explicitly by tagging itself.
  #
  # Skew gate at flip time: plugin 1.20.0 shipped 2026-08-05 and 1.20.1 on
  # 2026-08-06, against a 2-5 day release cadence. Note the drain could not be
  # evidenced directly — client_type was threaded into this gate but never
  # logged, so "untagged joins in Loki" was unobservable. The join-time log now
  # carries client_type (see EngramWeb.CrdtChannel) so a straggler is greppable:
  #   {service_name="engram"} | json | metadata_client_type=`untagged`
  # Pinned by test/engram/notes_crdt_origin_gate_test.exs. Tracked in #648.
  @untagged_crdt_client_type "web"

  @doc false
  @spec untagged_crdt_client_type() :: String.t()
  def untagged_crdt_client_type, do: @untagged_crdt_client_type

  @doc """
  ONE-REWRITER INVARIANT gate for CRDT-origin renames — BOTH legs reached via
  `genesis_crdt_note/5`: live relocates (`genesis_relocate_live`) and
  resurrect-renames (`genesis_resurrect`). `"obsidian"` never triggers a
  server rewrite; any other PRESENT tag does; an ABSENT tag (nil) takes the
  `untagged_crdt_client_type/0` default (see attribute comment).
  """
  @spec crdt_rename_rewrites?(String.t() | nil) :: boolean()
  def crdt_rename_rewrites?(client_type) do
    (client_type || @untagged_crdt_client_type) != "obsidian"
  end

  defp genesis_relocate_live(live, user, vault, sanitized_path, folder, origin) do
    with {:ok, query} <- note_by_path_query(user, vault, sanitized_path) do
      case Repo.one(query) do
        nil ->
          decrypted = decrypt_or_raise!(live, user)

          base_attrs = %{
            content: decrypted.content,
            title: decrypted.title,
            tags: decrypted.tags,
            content_hash: decrypted.content_hash,
            mtime: decrypted.mtime
          }

          case move_note(decrypted, base_attrs, user, sanitized_path, folder) do
            {:ok, {:moved, _prev_hash, updated, _merged_text, _content_hash}} ->
              case Crypto.maybe_decrypt_note_fields(updated, user) do
                {:ok, moved} ->
                  Logger.info(
                    "note_id_relocated",
                    Metadata.with_category(:info, :sync,
                      user_id: user.id,
                      vault_id: vault.id,
                      note_id: moved.id,
                      server_version: moved.version
                    )
                  )

                  # #591 — same-id CRDT relocate IS a rename (the primary
                  # rename path for web/plugin); re-resolve both basenames,
                  # same dedup-when-equal rule as do_rename_note_inner.
                  old_key = Links.basename_key(decrypted.path)
                  new_key = Links.basename_key(sanitized_path)

                  _ =
                    Enqueue.enqueue(
                      RebindNoteLinks.new_for(
                        user.id,
                        vault.id,
                        Links.basename_hmac(user, new_key)
                      ),
                      "rebind_note_links"
                    )

                  _ =
                    if new_key != old_key do
                      Enqueue.enqueue(
                        RebindNoteLinks.new_for(
                          user.id,
                          vault.id,
                          Links.basename_hmac(user, old_key)
                        ),
                        "rebind_note_links"
                      )
                    end

                  # #648/#1231 Phase 2 — server-side link rewrite for
                  # NON-obsidian CRDT-origin renames (the primary web rename
                  # path). Obsidian-origin relocates never enqueue: the plugin
                  # rewrites its own links (exactly-one-rewriter invariant).
                  # In-txn enqueue: the job commits atomically with the
                  # relocate; Enqueue.enqueue never raises.
                  _ =
                    if crdt_rename_rewrites?(origin) do
                      enqueue_crdt_rename_rewrite(user, vault, moved.id, decrypted.path)
                    end

                  # Carry the OLD path so the post-commit handler can fan an
                  # old-path delete to peers (a web receiver has no local mirror
                  # to drop the note from its old folder otherwise).
                  {:ok, moved, {:announce_moved, decrypted.path}}

                {:error, reason} ->
                  log_resurrect_decrypt_failure(reason, user, updated)
                  {:error, reason}
              end

            {:error, _} = err ->
              err

            # move_note lost its snapshot fence (#1335). These CRDT callers were
            # written against a two-shape contract, so the bare atom would raise
            # CaseClauseError. Report it the way every other genesis failure is
            # reported and let the client re-handshake against fresh state.
            :stale_snapshot ->
              {:error, :stale_snapshot}
          end

        %Note{} = _occupant ->
          Logger.warning(
            "note_id_collision_rejected",
            Metadata.with_category(:warning, :sync,
              user_id: user.id,
              vault_id: vault.id,
              note_id: live.id,
              server_version: live.version
            )
          )

          {:error, :id_conflict, decrypt_or_raise!(live, user)}
      end
    end
  end

  # CRDT relocates repoint the row in place (move_note) — no old-path
  # tombstone exists for the worker to decrypt, so the old path rides the
  # job args as user-DEK AES-GCM ciphertext, AAD-bound to the renamed row's
  # id (T3.2: plaintext never enters oban_jobs.args). get_dek should never
  # fail here (decrypt_or_raise! already proved this user's DEK usable in
  # this very function), but this runs INSIDE the relocate transaction and
  # a rewrite failure must never fail the rename — so an error skips the
  # enqueue (ids-only warning) instead of crashing the transaction.
  defp enqueue_crdt_rename_rewrite(user, vault, note_id, old_path) do
    case Crypto.get_dek(user) do
      {:ok, dek} ->
        aad = Crypto.aad_for_row("oban_rewrite_note_links", "old_path", note_id)
        {ct, nonce} = Envelope.encrypt(old_path, dek, aad)

        Enqueue.enqueue(
          RewriteNoteLinks.new_for(
            user.id,
            vault.id,
            :note,
            note_id,
            old_path_hmac_b64!(user, old_path),
            Base.encode64(Links.basename_hmac(user, Links.basename_key(old_path))),
            old_path_ciphertext: Base.encode64(ct),
            old_path_nonce: Base.encode64(nonce)
          ),
          "rewrite_note_links"
        )

      {:error, reason} ->
        Logger.warning(
          "crdt rename rewrite enqueue skipped: dek unavailable",
          Metadata.with_category(:warning, :sync,
            user_id: user.id,
            vault_id: vault.id,
            note_id: note_id,
            reason: inspect(reason)
          )
        )

        :ok
    end
  end

  defp genesis_resurrect(prior, user, vault, sanitized_path, folder, origin) do
    case Crypto.maybe_decrypt_note_fields(prior, user) do
      {:ok, prior} ->
        genesis_resurrect_decrypted(prior, user, vault, sanitized_path, folder, origin)

      {:error, reason} ->
        log_resurrect_decrypt_failure(reason, user, prior)
        {:error, reason}
    end
  end

  defp genesis_resurrect_decrypted(prior, user, vault, sanitized_path, folder, origin) do
    # FIX 1 — delete-wins (#970): a tombstone re-created at its OWN path within
    # the delete window is a stale device un-deleting a note another device
    # deleted. Mirror the REST upsert_pathless guard EXACTLY — refuse so the
    # delete stands; the client trashes its local copy on `recently_deleted`.
    # A rename (different path) lands outside this guard and resurrects below.
    if recent_same_path_tombstone?(prior, sanitized_path, user) do
      {:error, :recently_deleted}
    else
      # FIX 7 — did the path change? A rename restore must broadcast the
      # new-path upsert so peers converge; a same-path resurrect is covered by
      # announce_ready discovery alone. Decide by the decrypted prior path.
      renamed? = prior.path != sanitized_path

      base_attrs = %{
        content: prior.content,
        title: prior.title,
        tags: prior.tags,
        content_hash: prior.content_hash,
        mtime: prior.mtime
      }

      case move_note(prior, base_attrs, user, sanitized_path, folder) do
        {:ok, {:moved, _prev_hash, updated, _merged_text, _content_hash}} ->
          case Crypto.maybe_decrypt_note_fields(updated, user) do
            {:ok, decrypted} ->
              # #591 — treat a resurrect like a create: the note is live again
              # under sanitized_path, so danglers waiting on its basename can
              # bind.
              _ =
                Enqueue.enqueue(
                  RebindNoteLinks.new_for(
                    user.id,
                    decrypted.vault_id,
                    Links.basename_hmac(user, Links.basename_key(sanitized_path))
                  ),
                  "rebind_note_links"
                )

              # #648 Phase 2 — a resurrect-rename IS a rename (move_note over a
              # tombstoned row), so it owes the same server-side link rewrite
              # genesis_relocate_live enqueues, under the same one-rewriter
              # gate. Same in-txn, never-raises discipline; the old path rides
              # as AAD-bound ciphertext because move_note repointed the row and
              # left no old-path tombstone for the worker to read.
              _ =
                if renamed? and crdt_rename_rewrites?(origin) do
                  enqueue_crdt_rename_rewrite(user, vault, decrypted.id, prior.path)
                end

              # A rename-restore carries the OLD (tombstone) path so peers clear
              # it; a same-path resurrect just announces.
              tag = if renamed?, do: {:announce_moved, prior.path}, else: :announce
              {:ok, decrypted, tag}

            {:error, reason} ->
              log_resurrect_decrypt_failure(reason, user, updated)
              {:error, reason}
          end

        {:error, _} = err ->
          err

        # See genesis_relocate_live: move_note can now lose its snapshot fence.
        :stale_snapshot ->
          {:error, :stale_snapshot}
      end
    end
  end

  # Same operator-triage signal decrypt_or_raise!/2 emits, minus the raise —
  # genesis_resurrect must reply the client a clean create_failed, never crash
  # the channel over a corrupt/undecryptable row.
  defp log_resurrect_decrypt_failure(reason, user, %Note{} = note) do
    DecryptFailure.log("decrypt_failed", reason, user_id: user.id, note_id: note.id)
  end

  # Bare-insert leg of genesis_crdt_note/4: a brand-new id at a brand-new
  # path. Shares the insert body with insert_new_note/7 via do_bare_insert/6,
  # differing only in two ways: content is hardcoded "" (CRDT room owns real
  # content, delivered later via crdt_msg — never merge/broadcast content here),
  # and the recently_deleted_twin? guard is dropped entirely (that guard exists
  # to refuse a stale full-content re-push racing a delete; a genesis row
  # carries no content to be stale, so the guard has nothing to protect).
  # The Billing.check_limit notes_cap gate is kept — a genesis row still
  # counts against the tenant's note cap like any other insert.
  #
  # `id` is guaranteed a valid, cast UUID string by genesis_crdt_note/4's
  # single up-front validation point — unlike insert_new_note/7's optional
  # client_id, this id is REQUIRED, so there is no mint_id() fallback here.
  defp genesis_insert_bare(user, vault, id, sanitized_path, folder, lookup_query) do
    now = DateTime.utc_now()

    base_attrs = %{
      kind: "note",
      content: "",
      title: nil,
      tags: [],
      content_hash: nil,
      mtime: nil,
      user_id: user.id,
      vault_id: vault.id,
      created_at: now,
      updated_at: now
    }

    current_count = UsageMeters.notes_count(user.id)

    if match?({:error, :limit_reached}, Billing.check_limit(user, :notes_cap, current_count)) do
      limit = Billing.effective_limit(user, :notes_cap)
      {:error, {:notes_cap_reached, limit, current_count}}
    else
      # Shared create leg with insert_new_note/7 (do_bare_insert/6) — genesis
      # decrypts inline and tags :announce (a real create), a version_conflict
      # on a concurrent-create race.
      case do_bare_insert(base_attrs, user, sanitized_path, folder, id, lookup_query) do
        {:inserted, inserted, _crdt} ->
          # #591 — CRDT genesis create is the primary create path (web/plugin);
          # mirror upsert_note's create-branch rebind so danglers waiting on
          # this basename bind here too, not only on the REST path.
          _ =
            Enqueue.enqueue(
              RebindNoteLinks.new_for(
                user.id,
                vault.id,
                Links.basename_hmac(user, Links.basename_key(sanitized_path))
              ),
              "rebind_note_links"
            )

          {:ok, decrypt_or_raise!(inserted, user), :announce}

        {:raced, existing} ->
          {:error, :version_conflict, decrypt_or_raise!(existing, user)}

        {:error, _} = err ->
          err
      end
    end
  end

  # Phase 0 stale-base gate: a writer that declares the content_hash it READ
  # (`base_hash`) gets compare-and-swap semantics — if the row moved, the
  # write 409s instead of CRDT-merging. The merge diffs incoming FULL content
  # against the stored snapshot, so a stale full-content push deletes newer
  # content "convergently" (prod incident 2026-07-07). Absent base_hash keeps
  # the merge behavior for legacy clients.
  defp put_base_hash_opt(opts, attrs) do
    case attrs["base_hash"] || attrs[:base_hash] do
      base when is_binary(base) -> Keyword.put(opts, :base_hash, base)
      _ -> opts
    end
  end

  @doc """
  Kill every live CRDT room belonging to `vault_id`'s notes (#954). A room
  must not outlive its vault: orphaned rooms kept ticking checkpoints against
  rows being purged (the 2026-07-07 error storms). Brutal-kill via
  CrdtRegistry.terminate_room — no unbind checkpoint runs, and nothing is
  lost (tail-log holds every update; the vault is deleted anyway). Runs its
  own tenant scope; lookups for room-less notes are cheap (:global whereis).
  """
  @spec kill_live_rooms_for_vault(String.t(), String.t()) :: :ok
  def kill_live_rooms_for_vault(user_id, vault_id) do
    {:ok, ids} =
      Repo.with_tenant(user_id, fn ->
        Repo.all(from(n in Note, where: n.vault_id == ^vault_id, select: n.id))
      end)

    Enum.each(ids, &Engram.Notes.CrdtRegistry.terminate_room/1)

    # The vault's INDEX room (#1150) is keyed by vault, not note, so the loop
    # above cannot reach it. Same invariant, same reason (#954: a room must not
    # outlive its vault). The kill skips its #1151 checkpoint, which is correct
    # here — the vault is going, and vault_index_states cascades with it.
    Engram.Notes.CrdtIndexRegistry.terminate_room(vault_id)
    :ok
  rescue
    # Runs in delete_vault's post-commit tap: a raise here would surface as a
    # failure of an already-COMMITTED delete and skip the GateCache eviction
    # that follows. Cleanup never fails the write; orphaned rooms are killed
    # by deliver-time quarantine anyway.
    e ->
      Logger.warning(
        "crdt vault room teardown failed",
        Metadata.with_category(:warning, :sync,
          user_id: user_id,
          vault_id: vault_id,
          error: Exception.message(e)
        )
      )

      :ok
  end

  # Id-keyed rename support (Phase I): the plugin renames a note by keeping
  # the same client-minted id across `DELETE old` -> `POST new {id: same}`.
  # `delete_note/3` is a soft delete, so the tombstone row still holds PK=id
  # when the re-push lands. Looking the id up here (instead of assuming it is
  # free) is what lets upsert_note tell "reused id, move it" apart from
  # "fresh id, insert it".
  #
  # Runs inside the caller's `Repo.with_tenant` txn, so RLS already scopes
  # `Repo.get` to this user; the vault_id check below additionally guards
  # against a cross-vault id (same user, different vault) and a folder
  # marker sharing the id space. `Repo.get` has no soft-delete default scope
  # (Note carries no query default, only `note_by_path_query` filters
  # `deleted_at` explicitly), so this returns tombstones as well as live rows.
  # No live note exists at this path. Route by the client-supplied note_id.
  # Must run inside the caller's `Repo.with_tenant` block (does tenant-scoped
  # reads/writes).
  defp upsert_pathless(
         client_id,
         vault,
         base_attrs,
         user,
         sanitized_path,
         folder,
         tags,
         lookup_query
       ) do
    case existing_by_client_id(client_id, vault) do
      %Note{deleted_at: nil} = live ->
        # Live id-collision: this note_id already names a LIVE note at a
        # DIFFERENT path (there is no live note at THIS path — the lookup
        # missed). "rename A->B" and "a different note that reuses A's id" are
        # indistinguishable on the wire, and move_note would relocate +
        # crdt-merge A onto B, silently destroying A and bleeding its content
        # across notes (prod incident 2026-07-06). A real rename tombstones the
        # old path first (delete_note) and takes the resurrect branch below; a
        # live match here is a duplicate-id bug, so reject it as a conflict
        # rather than collapsing two distinct notes.
        {:id_collision, live}

      %Note{} = prior ->
        # `prior` is a TOMBSTONE (the live case took :id_collision above). Two
        # shapes share this branch and the path tells them apart:
        #   - id-keyed RENAME: same id re-pushed at a DIFFERENT path (delete old
        #     → push new) → resurrect via move_note.
        #   - DELETE-WINS conflict: same id re-pushed at its OWN path within the
        #     delete window — the note was deleted on another device and this is
        #     a stale re-push (possibly carrying local edits). Refuse so the
        #     delete stands; the client trashes its local copy on
        #     `recently_deleted` instead of wedging on a resurrect/409 forever.
        if recent_same_path_tombstone?(prior, sanitized_path, user) do
          {:error, :recently_deleted}
        else
          move_note(prior, base_attrs, user, sanitized_path, folder)
        end

      nil ->
        insert_new_note(base_attrs, user, sanitized_path, folder, tags, client_id, lookup_query)
    end
  end

  # A tombstone found by client id that sits at the SAME path as the incoming
  # push and was deleted within the delete-wins window — the local-edit-vs-
  # remote-delete signature. Distinguished from an id-keyed rename purely by
  # path (a rename lands at a different path). Best-effort: a filter-key error
  # falls back to false so a crypto hiccup never blocks a legitimate write.
  defp recent_same_path_tombstone?(%Note{deleted_at: nil}, _sanitized_path, _user), do: false

  defp recent_same_path_tombstone?(%Note{} = prior, sanitized_path, user) do
    cutoff = DateTime.add(DateTime.utc_now(), -@delete_tombstone_window_seconds, :second)

    DateTime.compare(prior.deleted_at, cutoff) != :lt and
      case Crypto.dek_filter_key(user) do
        {:ok, filter_key} -> prior.path_hmac == Crypto.hmac_field(filter_key, sanitized_path)
        _ -> false
      end
  end

  # Row-or-nil view of classify_by_id/2, kept for upsert_pathless's legacy REST
  # branching. A projection rather than a second copy of the rule: both used to
  # spell out cast -> Repo.get -> vault+kind, so a change to what counts as
  # "this vault's note" had to be made twice or the CRDT genesis path and the
  # REST path would silently disagree.
  defp existing_by_client_id(nil, _vault), do: nil

  defp existing_by_client_id(client_id, vault) do
    case classify_by_id(vault, client_id) do
      {:live, note} -> note
      {:tombstone, note} -> note
      _ -> nil
    end
  end

  # Moves/resurrects an existing row (found by client id, not by path) to
  # `sanitized_path`. Mirrors `do_rewrite_note/5`'s crdt-merge / encrypt /
  # phase_b / okf / seq / version+1 pipeline exactly, with three differences:
  #
  #   1. Clears the tombstone (`deleted_at: nil`) unconditionally.
  #   2. Restores the usage counter when the row WAS tombstoned (delete_note
  #      decremented it); a live-note move must NOT double-count.
  #   3. Never short-circuits on hash equality like `do_update_note` does: a
  #      pure rename has identical content but a changed path, so the row
  #      must always be rewritten to move the path/path_hmac.
  #
  # `Note.changeset/2` already carries the `notes_user_vault_path_v2` unique
  # constraint, so a rare race (another live note grabbed the target path
  # between the lookup and this update) surfaces as `{:error, changeset}`
  # instead of raising and aborting the tenant transaction.
  defp move_note(prior, base_attrs, user, sanitized_path, folder) do
    was_tombstoned = not is_nil(prior.deleted_at)

    with {:ok, crdt} <- maybe_merge_crdt(prior, base_attrs.content, user, prior.id) do
      merged_title = Helpers.extract_title(crdt.merged_text, sanitized_path)

      merged_attrs = %{
        base_attrs
        | content: crdt.merged_text,
          title: merged_title,
          tags: crdt.tags,
          content_hash: crdt.content_hash
      }

      with {:ok, encrypted} <- Crypto.encrypt_note_fields(merged_attrs, user, prior.id) do
        phase_b =
          inject_phase_b_fields(
            encrypted,
            user,
            prior.id,
            sanitized_path,
            folder,
            crdt.tags
          )
          |> inject_okf_fields(user, prior.id, crdt.merged_text)
          |> put_parse_status(crdt.merged_text)
          |> Map.put(:crdt_state_ciphertext, crdt.crdt_state_ciphertext)
          |> Map.put(:crdt_state_nonce, crdt.crdt_state_nonce)

        seq = Engram.Vaults.next_seq!(prior.vault_id)

        changeset =
          prior
          |> Note.changeset(Map.put(phase_b, :version, prior.version + 1))
          |> Ecto.Changeset.put_change(:seq, seq)
          |> Ecto.Changeset.put_change(:deleted_at, nil)

        # Same snapshot fence as do_rewrite_note, for the same reason: this
        # merges CRDT state from `prior.crdt_state` and then writes both
        # `content` and `crdt_state`, so a checkpoint committing in the gap
        # would be rolled back to the pre-checkpoint snapshot with its tail
        # already pruned. Fixing only do_rewrite_note left the rename and
        # id-keyed-move path clobbering checkpoints. #1335.
        #
        # `put_change(:deleted_at, nil)` means this can also resurrect a
        # tombstone, so the fence carries the whole pre-image, not just the id.
        case fenced_update(snapshot_fenced(changeset, prior)) do
          {:ok, updated} ->
            _ =
              if was_tombstoned do
                :ok = UsageMeters.inc_notes_count(user.id, 1)
              end

            # Tagged `:moved` (not the plain 4-tuple do_rewrite_note returns) so
            # the caller broadcasts unconditionally: a rename keeps the same
            # content_hash but persisted a new path/seq/version, and the plain
            # `prev_hash != content_hash` broadcast guard would skip it — leaving
            # peers with the old-path delete but no new-path upsert (the note
            # vanishes on them until their next pull).
            {:ok, {:moved, prior.content_hash, updated, crdt.merged_text, crdt.content_hash}}

          {:error, changeset} ->
            {:error, changeset}

          :stale_snapshot ->
            :stale_snapshot
        end
      end
    end
  end

  # PathSanitizer can silently rewrite an input path (drop `..`, strip illegal
  # chars, truncate). The note then lives at a path the client never asked for,
  # and the next pull's path_hmac won't match — the edit appears to "vanish".
  # Log it (note_id lets an operator pull the stored row) so the divergence is
  # not invisible. Plaintext paths stay out — they embed note titles/folders.
  defp maybe_log_path_rewrite(user, vault, original, sanitized, note_id) do
    if sanitized != original do
      Logger.warning(
        "note_path_rewritten",
        Metadata.with_category(:warning, :sync,
          user_id: user.id,
          vault_id: vault.id,
          note_id: note_id
        )
      )
    end
  end

  # A batch upsert reports per-entry status in its 200 body but logs nothing,
  # so partial drops (dup path/id, conflict, validation) are silent server-side.
  # Emit one summary so the failure is detectable + sized without grepping bodies.
  defp maybe_log_batch_rejects(user, results) do
    failed = Enum.count(results, &(&1.status != :ok))

    if failed > 0 do
      Logger.warning(
        "note_batch_partial_reject",
        Metadata.with_category(:warning, :sync,
          user_id: user.id,
          failed_count: failed,
          total_count: length(results)
        )
      )
    end
  end

  # CRDT (Yjs) is the only content-sync path: merge_plaintext in do_update_note
  # IS the conflict resolution. A stale client_version never 409s — the diverging
  # write is merged convergently into crdt_state (no legacy conflict-copy flow).
  defp do_update_note(existing, base_attrs, user, sanitized_path, folder, _tags, opts) do
    base_hash = Keyword.get(opts, :base_hash)

    cond do
      is_binary(existing.content_hash) and
        existing.content_hash == base_attrs.content_hash and
          not Keyword.get(opts, :force, false) ->
        idempotent_repush(existing, base_attrs)

      is_binary(base_hash) and is_binary(existing.content_hash) and
          existing.content_hash != base_hash ->
        # Stale base declared: the row moved since this writer read it. Refuse
        # to merge (see upsert_note — a stale full-content push deletes newer
        # content convergently); the writer re-reads and retries or surfaces a
        # conflict. Matches the long-documented-but-missing 409 contract.
        {:stale_base, existing}

      true ->
        do_rewrite_note(existing, base_attrs, user, sanitized_path, folder,
          db_mode: Keyword.get(opts, :db_mode)
        )
    end
  end

  # Idempotent re-push (plugin retry, offline-queue replay, MCP re-write):
  # the incoming content hashes identically to the stored merged content,
  # so the CRDT diff is a provable no-op. Skip the whole pipeline — CRDT
  # decrypt/merge/re-encrypt, field re-encryption, the row rewrite (TOAST
  # + WAL churn on the content blob), the version bump, and the seq
  # allocation — and return the row unchanged. The caller skips the
  # note_changed broadcast on hash equality, so other devices don't
  # reconcile a phantom change. Tradeoff: a same-content push with a newer
  # mtime keeps the stored mtime; sync state is hash/seq-based, so nothing
  # keys off it. Tombstones never reach here (note_by_path_query filters
  # deleted_at), so delete → re-push still resurrects via the insert path.
  # Repair paths that re-derive persisted fields from unchanged content
  # (e.g. Utf8Backfill fixing corrupt tags) pass `force: true` to opt out.
  # Return shape matches do_rewrite_note's 4-tuple: merged_text is the
  # incoming content (hash-equal to the stored merged content by the guard
  # in do_update_note), so callers thread the same digest fields either way.
  # Checked BEFORE the stale-base gate: a hash-equal push is a no-op whatever
  # base the writer declared.
  defp idempotent_repush(existing, base_attrs) do
    {:ok, {existing.content_hash, existing, base_attrs.content, existing.content_hash}}
  end

  # The whole read-then-write, retried ONCE when the write loses its snapshot
  # fence. #1335.
  #
  # The retry re-enters at the LOOKUP, not at `do_rewrite_note`. That matters:
  # everything between here and the write is a gate that has to be re-evaluated
  # against whatever is on disk now, not against the row we first read.
  #
  #   * the path lookup itself — the row may have been RENAMED in the gap, in
  #     which case this path no longer names it and re-reading by primary key
  #     would rewrite the OLD path's hmac/ciphertext and silently undo the
  #     rename. `note_by_path_query` also filters `deleted_at`, so a note
  #     deleted in the gap reads as absent instead of being rewritten and
  #     re-broadcast as an upsert.
  #   * `do_update_note`'s `base_hash` stale-base gate — the declared base may
  #     have been fresh against the first read and stale against this one.
  #   * `idempotent_repush` — the competing write may have made this push a
  #     provable no-op.
  #
  # ONE retry. The interleave is a genuine race, so a second loss means real
  # contention, and an unbounded loop against a hot note is a livelock.
  defp lookup_and_write(%{} = w, retries) do
    result =
      case Repo.one(w.query) do
        nil ->
          upsert_pathless(w.client_id, w.vault, w.base, w.user, w.path, w.folder, w.tags, w.query)

        existing ->
          # Test-only seam: parks here, between the row read and the write, so a
          # competing checkpoint can commit in the gap. `nil` in every
          # environment that does not set it, which is all of them outside
          # `test/support/checkpoint_interleave.ex`.
          interleave_hook(:after_note_read)
          do_update_note(existing, w.base, w.user, w.path, w.folder, w.tags, w.opts)
      end

    case result do
      :stale_snapshot when retries > 0 ->
        lookup_and_write(w, retries - 1)

      :stale_snapshot ->
        # Out of retries. Re-read so the conflict we hand back describes the row
        # as it actually is; `nil` means it was deleted, which the delete-wins
        # contract says must NOT come back as an authoritative "server note".
        case Repo.one(w.query) do
          nil ->
            {:error, :note_deleted}

          fresh ->
            # Distinct key. `{:conflict, _}` is also how a concurrent-INSERT
            # race reports, and upsert_note logs that as
            # `note_concurrent_insert_race` — a signal operators grep to reason
            # about duplicate creates. Emitting one more of those for every lost
            # snapshot fence would inflate that count and leave fence contention
            # with no signal of its own. #1335.
            Logger.warning(
              "note_write_snapshot_fence_lost",
              Metadata.with_category(:warning, :sync,
                user_id: w.user.id,
                note_id: fresh.id,
                server_version: fresh.version
              )
            )

            {:conflict, fresh}
        end

      other ->
        other
    end
  end

  defp interleave_hook(point) do
    case Application.get_env(:engram, :checkpoint_interleave_hook) do
      nil -> :ok
      fun when is_function(fun, 1) -> _ = fun.(point)
    end

    :ok
  end

  defp do_rewrite_note(existing, base_attrs, user, sanitized_path, folder, opts) do
    # db_opts carries `mode: :savepoint` on the batch path so a failed SQL
    # statement here (next_seq!'s UPDATE, or the Repo.update) rolls back to a
    # per-statement savepoint instead of poisoning the shared batch tx into
    # 25P02 and falsely failing sibling entries. Empty (default) on the
    # single-note path, which owns its whole tx (no siblings to protect, no
    # savepoint round-trip to pay for).
    db_opts =
      case Keyword.get(opts, :db_mode) do
        nil -> []
        mode -> [mode: mode]
      end

    with {:ok, crdt} <- maybe_merge_crdt(existing, base_attrs.content, user, existing.id) do
      merged_title = Helpers.extract_title(crdt.merged_text, sanitized_path)

      merged_attrs = %{
        base_attrs
        | content: crdt.merged_text,
          title: merged_title,
          tags: crdt.tags,
          content_hash: crdt.content_hash
      }

      with {:ok, encrypted} <- Crypto.encrypt_note_fields(merged_attrs, user, existing.id) do
        phase_b =
          inject_phase_b_fields(
            encrypted,
            user,
            existing.id,
            sanitized_path,
            folder,
            crdt.tags
          )
          |> inject_okf_fields(user, existing.id, crdt.merged_text)
          |> put_parse_status(crdt.merged_text)
          |> Map.put(:crdt_state_ciphertext, crdt.crdt_state_ciphertext)
          |> Map.put(:crdt_state_nonce, crdt.crdt_state_nonce)

        seq = Engram.Vaults.next_seq!(existing.vault_id, db_opts)

        changeset =
          existing
          |> Note.changeset(Map.put(phase_b, :version, existing.version + 1))
          |> Ecto.Changeset.put_change(:seq, seq)

        # #1335. The WHERE was the primary key ALONE, so this write landed on
        # top of anything that committed after `existing` was read.
        #
        # The fence is on `crdt_state_ciphertext`, NOT on `version`. That is the
        # whole point: `crdt` above was merged against `existing.crdt_state`, so
        # the snapshot is what this write's correctness depends on — and the
        # checkpoint branches that cause the loss (compaction, and the
        # structural/.canvas branch) rewrite `crdt_state` and PRUNE THE TAIL
        # while deliberately leaving `version` and `seq` untouched, precisely so
        # legacy /changes pullers see no phantom edit. A version fence is blind
        # to exactly the writer it needs to catch: replay_tail finds the pruned
        # rows gone, the merge silently uses the stale snapshot, the version
        # still matches, and the checkpoint's ops are destroyed.
        case fenced_update(snapshot_fenced(changeset, existing), db_opts) do
          # Thread crdt.content_hash (HMAC of projection) alongside merged_text
          # so callers can include the stored hash in broadcast digests without
          # re-deriving it.
          {:ok, updated} ->
            {:ok, {existing.content_hash, updated, crdt.merged_text, crdt.content_hash}}

          {:error, changeset} ->
            {:error, changeset}

          :stale_snapshot ->
            :stale_snapshot
        end
      end
    end
  end

  # Pin the write to the row pre-image the merge was computed against.
  #
  #
  # Set as changeset FILTERS rather than switching to `update_all`. Filters keep
  # `Repo.update`'s changeset validation — otherwise a failed cast is silently
  # dropped from `changes` and the write reports success — and its
  # `unique_constraint` mapping, which `do_move_note_inner`'s own comment relies
  # on to turn a path collision into `{:error, changeset}` rather than a raise
  # that aborts the tenant transaction. Ecto's Postgres adapter renders a nil
  # filter as `IS NULL`, so a never-checkpointed note is fenced correctly
  # instead of never matching.
  # `seq` is the always-present half. Every committing writer in this module
  # allocates a fresh one via `Vaults.next_seq!`, and `delete_note` bumps it
  # too — which is what makes a soft delete racing this write trip the fence
  # instead of getting the tombstone rewritten and re-broadcast as an upsert.
  # It is `NOT NULL`, so it can always be filtered on.
  #
  # `crdt_state_ciphertext` is the half that catches the checkpoint. Only added
  # when non-nil: Ecto renders a nil filter as `IS NULL` (correctly) but still
  # counts it when building the parameter list, so mixing one with a non-nil
  # filter raises `parameters must be of length N`. A row with no snapshot has
  # none to lose, and its `seq` still guards it.
  defp snapshot_fenced(changeset, %Note{crdt_state_ciphertext: nil} = pre) do
    %{changeset | filters: Map.put(changeset.filters, :seq, pre.seq)}
  end

  defp snapshot_fenced(changeset, %Note{} = pre) do
    %{
      changeset
      | filters:
          Map.merge(changeset.filters, %{
            seq: pre.seq,
            crdt_state_ciphertext: pre.crdt_state_ciphertext
          })
    }
  end

  # `Repo.update` RAISES `Ecto.StaleEntryError` when a filter matches zero rows;
  # it is not an `{:error, changeset}`. Turn it into a value so the caller can
  # decide. Nothing is suppressed — every caller either retries against a fresh
  # read or reports a conflict. The UPDATE itself succeeded (it matched no
  # rows), so there is no aborted-statement state and the enclosing transaction
  # stays usable, including on the `mode: :savepoint` batch path.
  defp fenced_update(changeset, db_opts \\ []) do
    Repo.update(changeset, db_opts)
  rescue
    Ecto.StaleEntryError -> :stale_snapshot
  end

  # Posture C CRDT bridge — runs INSIDE the caller's Repo.with_tenant txn.
  #
  # Implements a three-way convergent merge: builds the snapshot doc (ancestor)
  # and the tail doc (snapshot + replayed update-log tail) separately, then
  # applies the incoming change as a Yjs operation computed relative to the
  # snapshot. This preserves concurrent tail edits (live typing in the settle
  # window) alongside the incoming REST/MCP plaintext — neither side loses
  # keystrokes when they modify non-overlapping regions.
  #
  # Without tail replay (the old two-way diff), the converge-diff would delete
  # tail keystrokes from the doc and deliver_out would push those deletions to
  # open editors — the stale-snapshot window bug.
  #
  # Returns the merged text so callers compute content_hash + tags from the
  # MERGED result — the public-API contract is "server merges, never clobbers."
  defp maybe_merge_crdt(existing, incoming_content, user, note_id) do
    prior_state =
      case existing do
        %Note{} = note ->
          case Crypto.decrypt_crdt_state(note, user) do
            {:ok, state} -> state
            {:error, _} = err -> throw({:crdt_decrypt, err})
          end

        nil ->
          nil
      end

    # When the note has no snapshot (prior_state == nil), the three-way path
    # would build an empty snapshot_doc ancestor while replay_tail fills
    # tail_doc with the bind-time seed of the full text. The incoming REST diff
    # is then computed against the empty ancestor ("insert everything") and
    # applied onto the already-full tail — producing a full-body duplication
    # ("shared base + LIVEshared base + REST"). Concurrency preservation is lost
    # only in this legacy/pre-CRDT window, but that is strictly better than
    # duplicating the body.
    #
    # Two sub-cases share prior_state == nil:
    # - Brand-new insert (existing == nil): no tail rows can exist yet; skip
    #   replay entirely and call merge_plaintext/2 directly.
    # - Pre-CRDT update (existing is a %Note{} with nil crdt_state columns):
    #   tail rows MAY exist (bind/3 could have seeded the full text into the
    #   tail-log before any checkpoint ran). Replay the tail, then two-way-diff
    #   the incoming text against the tail-inclusive doc to avoid duplication.
    merge_result =
      cond do
        is_nil(prior_state) and is_nil(existing) ->
          # Brand-new insert: no note row, no tail rows can exist yet. Skip the
          # replay entirely and call merge_plaintext/2 directly (restores the
          # simple two-way path that predates tail-aware merging).
          CrdtBridge.merge_plaintext(nil, incoming_content)

        is_nil(prior_state) ->
          # Pre-CRDT note (existing %Note{} with nil crdt_state columns): tail
          # rows MAY exist (bind/3 seeds the full text into the tail-log before
          # any checkpoint). Replay the tail, then two-way-diff the incoming
          # text against the tail-inclusive doc to avoid full-body duplication.
          with {:ok, doc} <- CrdtBridge.doc_from_state(nil) do
            _count = CrdtPersistence.replay_tail(doc, user, note_id)
            CrdtBridge.merge_plaintext_into_doc(doc, incoming_content)
          end

        true ->
          with {:ok, snapshot_doc} <- CrdtBridge.doc_from_state(prior_state) do
            if CrdtBridge.body_of(snapshot_doc) == "" do
              # #1087 sibling of bind/3's seed guard: the ancestor check is
              # projected-BODY-emptiness, not snapshot-absence. A genesis row
              # stores an EMPTY-doc snapshot — three-way against that ancestor
              # turns the incoming diff into insert-everything, which unions
              # with a bind-time tail seed into a DOUBLED body. An
              # empty-projecting ancestor takes the same tail-inclusive
              # two-way path as a nil snapshot (reusing the hydrated doc keeps
              # the empty snapshot's lineage continuity).
              _count = CrdtPersistence.replay_tail(snapshot_doc, user, note_id)
              CrdtBridge.merge_plaintext_into_doc(snapshot_doc, incoming_content)
            else
              # Two independent docs from the same snapshot:
              # - snapshot_doc: the shared ancestor; the incoming diff is applied
              #   here to capture the minimal Yjs operations that encode the
              #   incoming change.
              # - tail_doc: snapshot + replayed tail; the captured incoming
              #   operations are applied here so Yjs merges them convergently
              #   with the tail operations.
              with {:ok, tail_doc} <- CrdtBridge.doc_from_state(prior_state) do
                # Fold in updates logged since the last checkpoint. Runs inside
                # the caller's with_tenant txn — no nested tenant context needed.
                _count = CrdtPersistence.replay_tail(tail_doc, user, note_id)

                CrdtBridge.merge_plaintext_relative_to_snapshot(
                  snapshot_doc,
                  tail_doc,
                  incoming_content
                )
              end
            end
          end
      end

    with {:ok, %{state: new_state, text: merged_text}} <- merge_result,
         {:ok, {ct, nonce}} <- Crypto.encrypt_crdt_state(new_state, user, note_id),
         {:ok, key} <- Crypto.dek_content_hash_key(user) do
      {:ok,
       %{
         crdt_state_ciphertext: ct,
         crdt_state_nonce: nonce,
         merged_text: merged_text,
         content_hash: Crypto.hmac_content_hash(key, merged_text),
         tags: Helpers.extract_tags(merged_text)
       }}
    end
  catch
    {:crdt_decrypt, err} -> err
  end

  @doc """
  Gets a note by path for a user. Returns {:ok, note} or {:error, :not_found}.
  """
  @spec get_note(map(), map(), String.t()) :: {:ok, Note.t()} | {:error, :not_found}
  def get_note(user, vault, path) do
    case find_note_by_path(user, vault, path) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, note} -> {:ok, decrypt_or_raise!(note, user)}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Current text of `note` from the authority, for callers that must
  read-modify-write it.

  `notes.content` is the REST/search **façade**. Since the server stopped
  authoring content (#1141) it is materialized from the CRDT doc at checkpoint,
  so between a doc write and its checkpoint the column lags. Reading it and
  writing back a derived full-content string is therefore data loss: the merge
  in `upsert_note/4` faithfully applies the diff it is given, and a diff
  computed from a blank base deletes the body (#1159).

  Resolution mirrors `ensure_projection_safe/2` in `Notes.CrdtCheckpoint`, so
  the two agree on which side is authoritative:

    * no `crdt_state` — nothing has been written through the doc, so the façade
      IS the authority (legacy/pre-CRDT rows).
    * `crdt_state` present — the doc is the authority, including when it
      projects empty. A genuine "user deleted all the text" persists deletion
      ops, so an empty projection there is real and must not be second-guessed.

  Tail replay is included for the same reason `maybe_merge_crdt/4` does it:
  ops committed since the last checkpoint are part of the current text.

  Called per debounced extraction by the link-extraction worker
  (`Engram.Workers.ExtractNoteLinks`), so it is no longer off the hot path —
  it decrypts and rebuilds a Yjs doc, so plain reads should still use
  `get_note/3` instead.
  """
  @spec authoritative_content(map(), Note.t()) :: {:ok, String.t()} | {:error, term()}
  def authoritative_content(user, %Note{} = note) do
    case Crypto.decrypt_crdt_state(note, user) do
      {:ok, nil} ->
        {:ok, note.content || ""}

      {:ok, state} ->
        with {:ok, doc} <- CrdtBridge.doc_from_state(state) do
          # replay_tail reads crdt_update_log, which is tenant-scoped. Callers
          # reach this from a controller rather than from inside upsert_note's
          # transaction, so establish the tenant here.
          Repo.with_tenant(user.id, fn ->
            _replayed = CrdtPersistence.replay_tail(doc, user, note.id)
          end)

          {:ok, CrdtBridge.project_doc(doc)}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Gets a note by its primary key id, scoped to the given user + vault.

  Returns `{:ok, note}` when found and owned by the caller, `{:error, :not_found}`
  otherwise (including cross-tenant lookups and soft-deleted rows). Mirrors the
  decrypt-on-read shape of `get_note/3` but keys by `notes.id` instead of
  `path_hmac` — used by URL-by-id endpoints where the client holds a stable id.

  RLS scopes the SELECT to the caller's tenant; the explicit
  `user_id`/`vault_id` predicate is belt-and-suspenders.
  """
  @spec get_note_by_id(map(), map(), String.t()) :: {:ok, Note.t()} | {:error, :not_found}
  def get_note_by_id(user, vault, id) when is_binary(id) do
    fetch_note_by_id(user, vault, id, :all)
  end

  @doc """
  Worker-side note fetch: loads by id with `skip_tenant_check` (trusted
  internal workers scope by note_id, not tenant) and maps the two dead-end
  states to an Oban `{:discard, reason}` — a vanished note or a soft-deleted
  one is permanently un-processable, so retrying would only burn attempts.
  Used by `Engram.Workers.EmbedNote` and `Engram.Workers.RepathNoteIndex`.
  """
  @spec fetch_note_for_worker(String.t()) :: {:ok, Note.t()} | {:discard, String.t()}
  def fetch_note_for_worker(note_id) do
    case Repo.get(Note, note_id, skip_tenant_check: true) do
      nil ->
        {:discard, "note #{note_id} not found"}

      %Note{deleted_at: deleted_at} when deleted_at != nil ->
        {:discard, "note #{note_id} is soft-deleted"}

      note ->
        {:ok, note}
    end
  end

  @doc """
  True when a live note with `note_id` exists in `vault_id` for `user`.

  Ownership check for the CRDT channel: doc_id is now the note_id, so the
  channel validates the id belongs to the vault (no decrypt, no path_hmac).
  Tenant-scoped via `Repo.with_tenant/2` — a bare query would trip the
  tenant guard.
  """
  @spec note_in_vault?(map(), Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def note_in_vault?(user, vault_id, note_id) do
    query = from(n in scoped_live(user, vault_id), where: n.id == ^note_id)

    case Repo.with_tenant(user.id, fn -> Repo.exists?(query) end) do
      {:ok, exists?} -> exists?
      _ -> false
    end
  end

  # Shared shell for by-id fetches; `fields: :meta` skips the content column
  # and its decrypt for callers that only need path/folder/tags (#863) —
  # same projection pattern the changes feeds use. `kind == "note"` excludes
  # folder-marker rows (they share the id space but aren't fetchable/
  # deletable through the by-id note API — CrdtTransport.load_doc and
  # delete_note_by_id both route through here, so neither can target a
  # folder marker).
  defp fetch_note_by_id(user, vault, id, fields) when is_binary(id) do
    with {:ok, user} <- Crypto.ensure_user_dek(user) do
      base = from(n in scoped_live(user, vault), where: n.id == ^id and n.kind == "note")

      query =
        case fields do
          :meta -> from(n in base, select: struct(n, @note_meta_fields))
          :all -> base
        end

      {:ok, result} =
        Repo.with_tenant(user.id, fn ->
          case Repo.one(query) do
            %Note{} = note -> {:ok, decrypt_or_raise!(note, user)}
            nil -> {:error, :not_found}
          end
        end)

      result
    end
  end

  # Phase B.2: single normalization helper for path lookups.
  # All callers route through here so post-B.3 column drop is mechanical.
  # Opens its own tenant context — use note_by_path_query/3 directly when
  # already inside Repo.with_tenant (Repo.with_tenant does not nest safely:
  # the inner `after` Process.delete clobbers the parent's tenant key).
  defp find_note_by_path(user, vault, path) do
    case note_by_path_query(user, vault, path) do
      {:ok, query} ->
        Repo.with_tenant(user.id, fn -> Repo.one(query) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Builds the HMAC-based note lookup query. Caller runs it inside their own
  # tenant context (or via find_note_by_path/3 when none is active).
  defp note_by_path_query(user, vault, path) do
    with {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      hmac = Crypto.hmac_field(filter_key, path)

      {:ok, from(n in scoped_live(user, vault), where: n.path_hmac == ^hmac)}
    end
  end

  # True when `path` holds a note tombstoned within the delete-wins window whose
  # stored content_hash equals the incoming push's — the resurrection signature
  # (a stale re-push of the exact note just deleted). A byte-different note or a
  # tombstone older than the window returns false, so a genuine re-create at the
  # same path is allowed. Best-effort: a filter-key error falls back to false
  # (never blocks a write on a crypto hiccup).
  defp recently_deleted_twin?(user, vault_id, path, content_hash) do
    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        hmac = Crypto.hmac_field(filter_key, path)
        cutoff = DateTime.add(DateTime.utc_now(), -@delete_tombstone_window_seconds, :second)

        Repo.exists?(
          from(n in scoped(user, vault_id),
            where:
              n.path_hmac == ^hmac and n.kind == "note" and not is_nil(n.deleted_at) and
                n.deleted_at >= ^cutoff and n.content_hash == ^content_hash
          )
        )

      _ ->
        false
    end
  end

  @doc """
  Returns a map of `path => id` for the given paths, scoped to a single user.

  Used by callers (e.g. search) that hold a path list (from Qdrant) and need
  the DB primary keys without decrypting full notes. Cross-vault: when
  `vault_id` is nil, scans across all of the user's vaults.

  Missing paths are simply absent from the returned map. The caller is
  expected to fall back to nil for ids it can't resolve.
  """
  @spec note_ids_for_paths(map(), map() | nil, [String.t()]) :: %{String.t() => integer()}
  def note_ids_for_paths(_user, _vault, []), do: %{}

  def note_ids_for_paths(user, vault, paths) when is_list(paths) do
    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        do_note_ids_for_paths(user, vault, paths, filter_key)

      _ ->
        %{}
    end
  end

  defp do_note_ids_for_paths(user, vault, paths, filter_key) do
    hmac_to_path =
      paths
      |> Enum.uniq()
      |> Map.new(fn p -> {Crypto.hmac_field(filter_key, p), p} end)

    hmacs = Map.keys(hmac_to_path)

    query =
      from(n in Note,
        where: n.user_id == ^user.id and n.path_hmac in ^hmacs and is_nil(n.deleted_at),
        select: {n.path_hmac, n.id}
      )

    query =
      case vault do
        %{id: vault_id} -> from(n in query, where: n.vault_id == ^vault_id)
        _ -> query
      end

    rows =
      case Repo.with_tenant(user.id, fn -> Repo.all(query) end) do
        {:ok, rows} when is_list(rows) -> rows
        rows when is_list(rows) -> rows
        _ -> []
      end

    Enum.reduce(rows, %{}, fn {hmac, id}, acc ->
      case Map.fetch(hmac_to_path, hmac) do
        {:ok, path} -> Map.put(acc, path, id)
        :error -> acc
      end
    end)
  end

  @doc """
  Renames a note to a new path. Sanitizes the new path, updates folder and title.
  Returns {:ok, updated_note} or {:error, :not_found}.
  """
  @spec rename_note(map(), map(), String.t(), String.t()) ::
          {:ok, Note.t()} | {:error, :not_found | :conflict}
  def rename_note(user, vault, old_path, new_path) do
    new_path = PathSanitizer.sanitize(new_path)
    new_folder = Helpers.extract_folder(new_path)
    now = DateTime.utc_now()

    with {:ok, user} <- Crypto.ensure_user_dek(user) do
      do_rename_note(user, vault, old_path, new_path, new_folder, now)
    end
  end

  defp do_rename_note(user, vault, old_path, new_path, new_folder, now) do
    {:ok, lookup_query} = note_by_path_query(user, vault, old_path)
    {:ok, target_query} = note_by_path_query(user, vault, new_path)

    result =
      Repo.with_tenant(user.id, fn ->
        cond do
          # No-op rename: same path. Skip target conflict check so the
          # request becomes idempotent rather than reporting a conflict
          # against itself.
          old_path == new_path ->
            case Repo.one(lookup_query) do
              nil -> :not_found
              note -> {:no_change, note}
            end

          Repo.one(target_query) ->
            # Pre-check the unique (user, vault, path_hmac) constraint so
            # the caller gets {:error, :conflict} instead of a Postgrex
            # unique_violation crash deeper in the encrypt/update path.
            :conflict

          true ->
            rename_with_retry(lookup_query, user, new_path, new_folder, now, 1)
        end
      end)

    case result do
      {:ok, {:ok, note}} ->
        # #746 — rename only changes the path; repath the existing Qdrant
        # points instead of re-embedding through Voyage. T3.2: base64 hmac, never plaintext.
        _ =
          Enqueue.enqueue(
            Engram.Workers.RepathNoteIndex.new_debounced(note.id,
              old_path_hmac: old_path_hmac_b64!(user, old_path)
            ),
            "repath_note_index"
          )

        # #648/#1231 — server-side link rewrite for REST/MCP-origin renames.
        # Plugin-origin renames never reach rename_note (Obsidian rewrites
        # those itself): exactly one party rewrites. Fire-and-forget: a
        # rewrite failure must never fail the rename.
        _ =
          Enqueue.enqueue(
            Engram.Workers.RewriteNoteLinks.new_for(
              user.id,
              vault.id,
              :note,
              note.id,
              old_path_hmac_b64!(user, old_path),
              Base.encode64(Links.basename_hmac(user, Links.basename_key(old_path)))
            ),
            "rewrite_note_links"
          )

        # #976 (same invariant as the folder-rename cascade): the note still
        # exists under the new path, so the old-path delete leg carries its id
        # for delete+upsert relocation correlation on receivers. Emit the
        # new-path upsert BEFORE the old-path delete: the receiver must
        # relocate the note's id to the new path first, so it recognizes the
        # delete as a relocation leg (id now lives elsewhere) instead of
        # tearing the note's CRDT room down by id before it can materialize.
        decrypted = decrypt_or_raise!(note, user)
        :ok = broadcast_change(user.id, vault.id, "upsert", note.path, decrypted, [])
        :ok = broadcast_change(user.id, vault.id, "delete", old_path, note.id, [])
        {:ok, decrypted}

      {:ok, {:no_change, note}} ->
        {:ok, decrypt_or_raise!(note, user)}

      {:ok, :conflict} ->
        {:error, :conflict}

      {:ok, :not_found} ->
        {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  # Retry ONCE on a lost fence, re-reading the row first — the mirror of
  # `lookup_and_write/2` on the write path. #1335.
  #
  # Without this a routine compaction checkpoint (which rewrites crdt_state on
  # every room exit whose text is unchanged) turns a rename of a note that
  # plainly exists into a 404. Worse for batch moves: `reduce_move_notes/4` maps
  # `{:error, :not_found}` to `Repo.rollback({:not_found, id})`, so ONE note
  # losing its fence aborts the entire atomic move.
  #
  # Re-reading is what makes the retry meaningful: `do_rename_note_inner`
  # rebuilds every ciphertext column from the row it was handed, so retrying
  # with the stale struct would just lose the fence again and write pre-read
  # plaintext if it did not.
  defp rename_with_retry(lookup_query, user, new_path, new_folder, now, retries) do
    case Repo.one(lookup_query) do
      nil ->
        :not_found

      note ->
        case do_rename_note_inner(note, user, new_path, new_folder, now) do
          :stale_snapshot when retries > 0 ->
            rename_with_retry(lookup_query, user, new_path, new_folder, now, retries - 1)

          :stale_snapshot ->
            Logger.warning(
              "note_rename_snapshot_fence_lost",
              Metadata.with_category(:warning, :sync, user_id: user.id, note_id: note.id)
            )

            :not_found

          other ->
            other
        end
    end
  end

  # Nonce, not ciphertext: 12 random bytes rewritten by every write of the
  # column, so it discriminates identically without shipping a TOASTed blob as a
  # bind parameter. Compared only when non-nil (`= NULL` is never true).
  defp rename_fence(%Note{id: id, seq: seq, crdt_state_nonce: nil}),
    do: from(n in Note, where: n.id == ^id and n.seq == ^seq)

  defp rename_fence(%Note{id: id, seq: seq, crdt_state_nonce: nonce}),
    do: from(n in Note, where: n.id == ^id and n.seq == ^seq and n.crdt_state_nonce == ^nonce)

  defp do_rename_note_inner(note, user, new_path, new_folder, now) do
    decrypted_note = decrypt_or_raise!(note, user)
    new_title = Helpers.extract_title(decrypted_note.content || "", new_path)

    # T3.6 — rename converges the row to AAD-bound. We have content
    # and tags decrypted in memory already; re-encrypt them with the
    # row-id-bound AAD so all five ciphertext columns share a
    # consistent dek_version=2 stamp. Skipping content/tags would
    # leave the row mixed (path/folder/title bound, content/tags
    # legacy) and the read-side AAD dispatch keys off a single
    # row.dek_version — a mixed row breaks decrypt for whichever
    # group disagrees with the stamped version.
    full_kw =
      full_aad_bound_kw(
        user,
        note.id,
        decrypted_note.content || "",
        new_title,
        new_path,
        new_folder,
        decrypted_note.tags || []
      )

    seq = Engram.Vaults.next_seq!(note.vault_id)

    # Fenced on the row pre-image this rename derived from. #1335, same class.
    # `full_kw` rebuilds ALL five ciphertext columns from `decrypted_note`,
    # which was read at the top of this function, so anything committing in
    # between — a checkpoint materializing live text, or a concurrent
    # `upsert_note` — was overwritten by that pre-read plaintext under the old
    # primary-key-only WHERE.
    #
    # `seq` is the always-present half; `crdt_state_ciphertext` catches the
    # checkpoint branches that rewrite the snapshot without touching seq, and is
    # only compared when non-nil because `= NULL` is never true.
    {count, _} =
      note
      |> rename_fence()
      |> Repo.update_all(
        set:
          [
            updated_at: now,
            seq: seq
          ] ++ full_kw
      )

    if count == 1 do
      # Insert a soft-deleted tombstone for the OLD path so the seq-cursor
      # change feed carries a durable `{old_path, deleted: true}` delete
      # signal. Without it, an offline client that reconnects and pulls by
      # cursor sees only the repointed live row at `new_path` and keeps a
      # duplicate at `old_path` (#614, single-note analogue). Mirrors the
      # `do_rename_folder/5` cascade: a fresh row-id-bound full-row insert,
      # stamped with the SAME `seq` as the repoint above so a cursor pull
      # (`WHERE seq > cursor`) can't observe the repoint at seq S, advance
      # past S, and miss the tombstone (also S). Built from in-memory data so
      # it folds into this same `Repo.with_tenant` transaction. The tombstone
      # never enqueues EmbedNote — only the renamed live note does.
      old_path = decrypted_note.path
      tomb_id = mint_id()
      mtime_float = DateTime.to_unix(now) + 0.0

      tomb_kw =
        full_aad_bound_kw(user, tomb_id, "", "", old_path, Helpers.extract_folder(old_path), [])

      tombstone =
        Map.merge(
          %{
            id: tomb_id,
            content_hash: "",
            mtime: mtime_float,
            user_id: user.id,
            vault_id: note.vault_id,
            created_at: now,
            updated_at: now,
            deleted_at: now,
            seq: seq
          },
          Map.new(tomb_kw)
        )

      # `on_conflict: :nothing` is belt-and-suspenders — the tombstone has a
      # fresh UUIDv7 PK and `deleted_at != nil` excludes it from the partial
      # unique path index, so a conflict is structurally impossible today. Log
      # if that ever stops holding (e.g. an index-semantics change), since a
      # dropped tombstone silently reopens the offline-resurrection gap.
      {inserted, _} = Repo.insert_all(Note, [tombstone], on_conflict: :nothing)

      if inserted == 0 do
        require Logger

        Logger.warning(
          "rename_note tombstone dropped on conflict",
          Metadata.with_category(:warning, :sync, vault_id: note.vault_id)
        )
      end

      # #591 — re-resolve edges for BOTH basenames: the new name may bind
      # danglers waiting on it, and the old name's remaining candidates
      # (a same-basename sibling elsewhere) may need to inherit the edges
      # this note is vacating.
      old_key = Links.basename_key(old_path)
      new_key = Links.basename_key(new_path)

      _ =
        Enqueue.enqueue(
          RebindNoteLinks.new_for(user.id, note.vault_id, Links.basename_hmac(user, new_key)),
          "rebind_note_links"
        )

      _ =
        if new_key != old_key do
          Enqueue.enqueue(
            RebindNoteLinks.new_for(user.id, note.vault_id, Links.basename_hmac(user, old_key)),
            "rebind_note_links"
          )
        end

      # Splice the freshly-encrypted ciphertext + dek_version=2
      # into the in-memory struct so callers (broadcast, MCP,
      # controllers) read the new plaintext without re-decrypting
      # through maybe_decrypt_note_fields.
      {:ok,
       note
       |> struct!(full_kw)
       |> struct!(
         content: decrypted_note.content,
         tags: decrypted_note.tags || [],
         path: new_path,
         folder: new_folder,
         title: new_title,
         embed_hash: nil,
         updated_at: now
       )}
    else
      # Zero rows means one of two things, and they want different handling:
      # the row is genuinely gone, or the snapshot fence caught a write that
      # committed under us (#1335). Only probe on this rare miss path.
      #
      # `is_nil(deleted_at)`: a concurrent DELETE bumps seq and so also loses the
      # fence, and without this filter it would report as a fence loss —
      # destroying the exact distinction this probe exists to draw.
      if Repo.exists?(from(n in Note, where: n.id == ^note.id and is_nil(n.deleted_at))) do
        # Live row, stale pre-image. `rename_with_retry/6` re-reads and tries
        # again; only if THAT loses too does the caller see :not_found.
        :stale_snapshot
      else
        :not_found
      end
    end
  end

  @doc """
  Soft-deletes a note. Idempotent — returns :ok even if note doesn't exist.
  Also cleans up Qdrant points and chunk records for the deleted note.

  Options:
    * `:origin_device_id` — opaque device identity of the caller (from the
      X-Device-Id header), stamped into the `note_changed` broadcast so the
      originating device can drop its own echo (#970).
  """
  @spec delete_note(map(), map(), String.t(), keyword()) :: :ok
  def delete_note(user, vault, path, opts \\ []) do
    now = DateTime.utc_now()

    note =
      case find_note_by_path(user, vault, path) do
        {:ok, note} -> note
        _ -> nil
      end

    # No-op deletes (unknown / already-deleted path) announce nothing (#971):
    # nothing changed, and the empty-id delete events they used to fan out
    # were pure noise at best (mirrors do_delete_attachment's `if deleted?`).
    _ =
      if note do
        _ =
          Repo.with_tenant(user.id, fn ->
            seq = Engram.Vaults.next_seq!(vault.id)

            {updated, _} =
              from(n in Note, where: n.id == ^note.id and is_nil(n.deleted_at))
              |> Repo.update_all(set: [deleted_at: now, updated_at: now, seq: seq])

            # Decrement by rows actually transitioned live → deleted, so a
            # concurrent delete (already-nil deleted_at) can't double-count.
            :ok = UsageMeters.dec_notes_count(user.id, updated)
          end)

        # `path` (the caller's own plaintext argument) is in scope here even
        # though `note` itself is the raw undecrypted row — no extra decrypt
        # needed to compute the basename hmac for DeleteNoteIndex's chained
        # rebind (#591).
        _ =
          Enqueue.enqueue(
            delete_note_index_job(note, Links.basename_hmac(user, Links.basename_key(path))),
            "delete_note_index"
          )

        broadcast_change(user.id, vault.id, "delete", path, note.id, opts)
      end

    :ok
  end

  @doc """
  Soft-deletes a note by its primary key id, scoped to the given user + vault.

  Returns `:ok` on success, `{:error, :not_found}` when the id doesn't resolve
  to a live note owned by the caller (unlike `delete_note/4` which is
  idempotent — callers of URL-by-id endpoints want a hard 404 signal).

  Delegates to `delete_note/4` once ownership is verified, so Qdrant cleanup +
  usage-meter decrement + `note_changed` broadcast all run as a side-effect.
  """
  @spec delete_note_by_id(Engram.Accounts.User.t(), map(), String.t(), keyword()) ::
          :ok | {:error, :not_found}
  def delete_note_by_id(user, vault, id, opts \\ []) when is_binary(id) do
    case get_note_by_id(user, vault, id) do
      {:ok, note} -> delete_note(user, vault, note.path, opts)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Atomically soft-deletes a list of notes by id, scoped to the caller's
  user + vault. All-or-nothing: if any id fails to resolve to a live note
  owned by the caller, nothing is deleted.

  Set-based (#863): ONE meta-projected `id IN (...)` fetch (no content read
  or decrypt), ONE shared seq for the whole batch (the previous per-id
  `next_seq!` composition took the vault row lock N times and held it to
  commit — a serialization point for every concurrent write to the vault),
  ONE `update_all`, and a bulk `Oban.insert_all` for the index cleanup jobs.
  The missing-id check runs BEFORE any write, so all-or-nothing needs no
  rollback of partial work.

  Broadcasts fire AFTER the transaction commits — the old per-id
  composition leaked `note_changed` events for work that later rolled back.
  NOTE: this fixes batch DELETE only; `batch_move_notes/4` and the folder
  batch ops still broadcast mid-transaction (their moduledocs carry the
  caveat) — the systemic after-commit buffer remains a follow-up.

  Duplicate ids collapse to a single delete (idempotent-delete semantics);
  folder-marker ids are NOT deletable here (use the folder APIs) and read
  as not_found. Returns `{:ok, %{deleted: n}}` (n = distinct live notes
  deleted) or `{:error, {:not_found, id}}` for the first unresolvable id.
  """
  @spec batch_delete_notes(map(), map(), [String.t()]) ::
          {:ok, %{deleted: non_neg_integer()}}
          | {:error, {:not_found, String.t()} | term()}
  def batch_delete_notes(_user, _vault, []), do: {:ok, %{deleted: 0}}

  def batch_delete_notes(user, vault, ids) when is_list(ids) do
    # Duplicate ids collapse to one delete (idempotent-delete semantics);
    # `deleted` counts DISTINCT notes, documented in the @doc above.
    ids = Enum.uniq(ids)

    with {:ok, user} <- Crypto.ensure_user_dek(user) do
      {:ok, result} =
        Repo.with_tenant(user.id, fn ->
          # kind filter: folder-marker rows share the notes table but have
          # nil path_hmac and their own delete API — a marker id here must
          # read as not_found, not tombstone the marker + crash on encode64.
          notes =
            Repo.all(
              from(n in scoped_live(user, vault),
                where: n.id in ^ids and n.kind == "note",
                select: struct(n, @note_meta_fields)
              )
            )

          found = MapSet.new(notes, & &1.id)

          case Enum.find(ids, &(not MapSet.member?(found, &1))) do
            nil ->
              seq = Engram.Vaults.next_seq!(vault.id)
              now = DateTime.utc_now()

              # One shared timestamp for every tombstone — the seq feed orders
              # by (seq, id), so same-stamp runs are harmless (the timestamp
              # chunking that used to live here served the retired legacy feed).
              {updated, _} =
                from(n in Note, where: n.id in ^ids and is_nil(n.deleted_at))
                |> Repo.update_all(set: [deleted_at: now, updated_at: now, seq: seq])

              :ok = UsageMeters.dec_notes_count(user.id, updated)

              # Jobs insert inside the txn, so a failure rolls them back with
              # the tombstones. insert_all trades Enqueue.enqueue's per-job
              # telemetry for one statement; {_count, _} match keeps failures
              # loud (insert_all raises on error).
              #
              # #591 — `notes` here is the pre-decrypt meta projection (no
              # plaintext path in scope yet; decrypt happens post-commit below
              # for the broadcast), so `delete_note_index_job/1` gets no
              # basename_key — DeleteNoteIndex's chained rebind is skipped.
              # `Links.on_note_soft_deleted/2` (edge-flip) still runs
              # unconditionally inside DeleteNoteIndex regardless. The
              # same-basename-sibling rebind itself is NOT skipped for batch
              # delete though — it's enqueued directly post-commit below,
              # once plaintext paths exist (reusing the broadcast's decrypt).
              jobs = Enum.map(notes, &delete_note_index_job/1)
              _ = if jobs != [], do: Oban.insert_all(jobs)

              {:ok, %{deleted: updated, notes: notes}}

            missing ->
              {:error, {:not_found, missing}}
          end
        end)

      case result do
        {:ok, %{deleted: deleted, notes: notes}} ->
          # Post-commit: same per-note delete events clients already handle.
          # Meta rows decrypt cheaply (path envelope only — no content).
          zipped = notes |> Crypto.decrypt_notes_batch(user) |> Enum.zip(notes)

          Enum.each(zipped, fn
            {{:ok, note}, raw} ->
              broadcast_change(user.id, vault.id, "delete", note.path, raw.id, [])

            {{:error, reason}, raw} ->
              # The tombstone committed; only the broadcast is lost. Fail
              # LOUD in logs (read paths raise on decrypt failures) so a
              # corrupt path envelope doesn't vanish silently — other
              # devices reconcile on their next pull via the seq feed.
              Logger.error(
                "batch_delete broadcast skipped: undecryptable path envelope",
                Metadata.with_category(:error, :crypto,
                  user_id: user.id,
                  vault_id: vault.id,
                  note_id: raw.id,
                  reason: inspect(reason)
                )
              )
          end)

          # #591 — plaintext paths are already decrypted right above for the
          # broadcast; piggyback the same-basename-sibling rebind here rather
          # than re-decrypting inside the transaction. Dedup within the batch
          # (deleting several notes that share a basename should only enqueue
          # one rebind per key).
          zipped
          |> Enum.flat_map(fn
            {{:ok, note}, _raw} -> [Links.basename_key(note.path)]
            {{:error, _}, _raw} -> []
          end)
          |> Enum.uniq()
          |> Enum.each(fn key ->
            _ =
              Enqueue.enqueue(
                RebindNoteLinks.new_for(user.id, vault.id, Links.basename_hmac(user, key)),
                "rebind_note_links"
              )
          end)

          {:ok, %{deleted: deleted}}

        {:error, _} = err ->
          err
      end
    end
  end

  # T3.2 — base64 path_hmac, never plaintext. Single builder shared by
  # delete_note/3, batch_delete_notes/3, and the folder-delete cascade so an
  # arg change cannot drift between sites (silently orphaning Qdrant points).
  #
  # #591 — `basename_hmac` (base64, T3.2/H3 — see no_plaintext_args_test.exs)
  # lets DeleteNoteIndex chain a rebind so a shadowed same-basename sibling
  # can inherit this note's edges. Optional: a caller without plaintext in
  # scope at this point (batch_delete_notes' pre-commit job build) passes nil
  # and DeleteNoteIndex skips the rebind — `Links.on_note_soft_deleted/2`
  # (edge-flip) still always runs.
  defp delete_note_index_job(note, basename_hmac \\ nil) do
    args = %{
      note_id: note.id,
      user_id: note.user_id,
      vault_id: note.vault_id,
      path_hmac: Base.encode64(note.path_hmac)
    }

    args =
      if basename_hmac,
        do: Map.put(args, :basename_hmac, Base.encode64(basename_hmac)),
        else: args

    DeleteNoteIndex.new(args)
  end

  @doc """
  Atomic batch move. Each note in `ids` is moved into the folder identified
  by `target_folder_id` (a folder-marker row's id, scoped to the caller's
  user + vault).

  Semantics:

  - All-or-nothing transaction. On any failure (missing/cross-vault note id,
    missing target marker, destination path collision), every prior move in
    the batch rolls back.
  - Returns `{:ok, %{moved: n}}` on success (n = `length(ids)`).
  - Returns `{:error, {:not_found, id}}` for a missing or cross-vault note id,
    or for a missing target folder marker (with `id == target_folder_id`).
  - Returns `{:error, {:conflict, id}}` when the destination path is already
    taken by another note in the same vault.

  Empty list short-circuits to `{:ok, %{moved: 0}}` without opening a
  transaction or resolving the marker.

  PubSub disclosure (same caveat as `batch_delete_notes/3`): `rename_note/4`
  fires `note_changed` broadcasts per id during the transaction. PubSub is
  NOT transactional — subscribers may receive events for moves that get
  rolled back when a later id in the batch fails. The systemic fix
  (after-commit hooks so broadcasts only fire post-commit) is tracked as a
  follow-up and will land before more batch ops are added.
  """
  @spec batch_move_notes(map(), map(), [String.t()], String.t() | {:path, String.t()}) ::
          {:ok, %{moved: non_neg_integer()}}
          | {:error, {:not_found | :conflict, String.t()} | term()}
  def batch_move_notes(_user, _vault, [], _target_folder_id), do: {:ok, %{moved: 0}}

  # Move into a folder given by PATH. No marker is required — a "derived" folder
  # exists purely as a path on its notes. `folder == ""` means the vault root.
  def batch_move_notes(user, vault, ids, {:path, folder})
      when is_list(ids) and is_binary(folder) do
    Repo.transaction(fn ->
      case Crypto.ensure_user_dek(user) do
        {:ok, user} -> reduce_move_notes(user, vault, ids, folder)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def batch_move_notes(user, vault, ids, "root") when is_list(ids) do
    batch_move_notes(user, vault, ids, {:path, ""})
  end

  def batch_move_notes(user, vault, ids, target_folder_id)
      when is_list(ids) and is_binary(target_folder_id) do
    Repo.transaction(fn ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, marker} <- get_folder_marker_by_id(user, vault, target_folder_id),
           {:ok, dek} <- Crypto.get_dek(user) do
        target_folder = hydrate_folder_marker(marker, dek).folder
        reduce_move_notes(user, vault, ids, target_folder)
      else
        {:error, :not_found} -> Repo.rollback({:not_found, target_folder_id})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Shared move loop (runs inside a transaction): move each id into
  # `target_folder` (a path), rolling the whole batch back on the first failure.
  # move_note_into_folder wraps a path collision as {:error, {:conflict, id}};
  # the bare :not_found from the inner get_note_by_id is tagged with its id here.
  defp reduce_move_notes(user, vault, ids, target_folder) do
    ids
    |> Enum.reduce_while(%{moved: 0}, fn id, acc ->
      case move_note_into_folder(user, vault, id, target_folder) do
        {:ok, _} -> {:cont, Map.update!(acc, :moved, &(&1 + 1))}
        {:error, {kind, id_err}} -> {:halt, {:rollback, {kind, id_err}}}
        {:error, :not_found} -> {:halt, {:rollback, {:not_found, id}}}
      end
    end)
    |> case do
      {:rollback, reason} -> Repo.rollback(reason)
      acc -> acc
    end
  end

  # ---------------------------------------------------------------------------
  # Batch upsert (sync protocol rev — bulk push)
  # ---------------------------------------------------------------------------

  # Persisted columns written by the batch-insert path. Mirrors what the
  # single-note changeset INSERT produces; timestamps are merged separately
  # because `insert_all` does not autogenerate them.
  @batch_insert_columns [
    :id,
    :kind,
    :version,
    :dek_version,
    :content_hash,
    :mtime,
    :user_id,
    :vault_id,
    :content_ciphertext,
    :content_nonce,
    :title_ciphertext,
    :title_nonce,
    :tags_ciphertext,
    :tags_nonce,
    :path_ciphertext,
    :path_nonce,
    :path_hmac,
    :basename_hmac,
    :folder_ciphertext,
    :folder_nonce,
    :folder_hmac,
    :tags_hmac,
    :fm_timestamp,
    :fm_created,
    :type_ciphertext,
    :type_nonce,
    :type_hmac,
    :description_ciphertext,
    :description_nonce,
    :resource_ciphertext,
    :resource_nonce,
    :parse_status,
    :parse_reason
  ]

  @doc """
  Bulk create/update of notes in ONE tenant transaction.

  Protocol-rev counterpart of `upsert_note/3` for the plugin's bulk/initial
  sync: one `path_hmac IN (...)` lookup for the whole batch, per-note encrypt,
  a single `insert_all` for new rows, one usage-meter increment, one
  `Oban.insert_all` for embed jobs, and one `notes.batch` digest broadcast
  (op `"upsert"`, metadata-only — no content) instead of N `note_changed`
  events.

  Returns `{:ok, %{results: [...]}}` with one entry per input note, in input
  order:

    * `%{path, status: :ok, id, version, content_hash}`
    * `%{path, status: :conflict, server_note: %Note{}}` — stale client
      version; the decrypted server note mirrors today's single-note 409 body
      so 3-way merge keeps working. Does not block other entries.
    * `%{path, status: :error, errors: term}` — per-note validation failure
      (blank path, duplicate path within the batch, invalid changeset). Does
      not block other entries.

  Whole-batch failure: `{:error, {:notes_cap_reached, limit, current}}` when
  the would-be inserts exceed the plan's notes cap (nothing is committed —
  mirrors the single-note 402 so the client can fall back / surface upgrade).

  Batch size is capped at the controller boundary (100), matching the other
  batch endpoints.
  """
  @spec batch_upsert_notes(map(), map(), [map()]) ::
          {:ok, %{results: [map()]}}
          | {:error, {:notes_cap_reached, non_neg_integer(), non_neg_integer()}}
          | {:error, term()}
  def batch_upsert_notes(_user, _vault, []), do: {:ok, %{results: []}}

  def batch_upsert_notes(_user, _vault, notes_params)
      when is_list(notes_params) and length(notes_params) > @max_batch_entries,
      do: {:error, :batch_too_large}

  def batch_upsert_notes(user, vault, notes_params) when is_list(notes_params) do
    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      entries = normalize_batch_entries(user, filter_key, notes_params)

      case Repo.with_tenant(user.id, fn -> run_batch_upsert(user, vault, entries) end) do
        {:ok, state} ->
          batch_upsert_side_effects(user, vault, state)
          results = batch_upsert_results(user, state.entries)
          maybe_log_batch_rejects(user, results)
          {:ok, %{results: results}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Parse + sanitize each entry outside the transaction (pure CPU). Marks
  # blank paths and intra-batch duplicates (by sanitized-path HMAC) as
  # per-note errors so they never reach the write path.
  defp normalize_batch_entries(user, filter_key, notes_params) do
    notes_params
    |> Enum.map(fn attrs ->
      path = attrs["path"] || attrs[:path]
      # Scrub invalid UTF-8 on the batch write path too (POST /api/notes/batch),
      # not just upsert_note/4 — otherwise a batch push re-persists corruption and
      # its digest broadcast crashes the same way (#727/#738).
      content = (attrs["content"] || attrs[:content] || "") |> Helpers.scrub_utf8(:write)

      if path in [nil, ""] do
        %{input_path: path || "", result: {:error, %{path: ["can't be blank"]}}}
      else
        sanitized = PathSanitizer.sanitize(path)
        {:ok, hash} = content_hash(user, content)

        %{
          input_path: path,
          path: sanitized,
          path_hmac: Crypto.hmac_field(filter_key, sanitized),
          content: content,
          mtime: attrs["mtime"] || attrs[:mtime],
          client_id: attrs["id"] || attrs[:id],
          title: Helpers.extract_title(content, sanitized),
          folder: Helpers.extract_folder(sanitized),
          tags: Helpers.extract_tags(content),
          hash: hash,
          result: nil
        }
      end
    end)
    |> mark_duplicate_paths()
  end

  # Marks intra-batch duplicates as per-note errors: by sanitized-path HMAC
  # (second write would be an update-of-uncommitted-row) and by client id
  # (two rows with one PK in a single insert_all raises "cannot affect row
  # a second time" even under ON CONFLICT, aborting the whole batch).
  # Set of {path_hmac, content_hash} for notes at `hmacs` tombstoned within the
  # delete-wins window — the batch-path twin of `recently_deleted_twin?/4`.
  defp recent_delete_twins(_user, _vault, []), do: MapSet.new()

  defp recent_delete_twins(user, vault, hmacs) do
    cutoff = DateTime.add(DateTime.utc_now(), -@delete_tombstone_window_seconds, :second)

    Repo.all(
      from(n in scoped(user, vault),
        where:
          n.kind == "note" and n.path_hmac in ^hmacs and not is_nil(n.deleted_at) and
            n.deleted_at >= ^cutoff,
        select: {n.path_hmac, n.content_hash}
      )
    )
    |> MapSet.new()
  end

  # Marks pending CREATE-entries whose (path_hmac, content_hash) matches a
  # recent tombstone as per-note `recently_deleted` errors — delete-wins for the
  # batch path. An entry whose hmac has a LIVE note is a normal update and is
  # left alone (it takes process_batch_entry's `existing ->` branch downstream).
  defp mark_recently_deleted(entries, existing_by_hmac, twins) do
    if MapSet.size(twins) == 0 do
      entries
    else
      Enum.map(entries, fn
        %{result: nil, path_hmac: hmac, hash: hash} = entry ->
          if not Map.has_key?(existing_by_hmac, hmac) and MapSet.member?(twins, {hmac, hash}) do
            %{entry | result: {:error, %{reason: "recently_deleted"}}}
          else
            entry
          end

        other ->
          other
      end)
    end
  end

  defp mark_duplicate_paths(entries) do
    {marked, _seen} =
      Enum.map_reduce(entries, {MapSet.new(), MapSet.new()}, fn entry, {paths, ids} ->
        case entry do
          %{result: nil, path_hmac: hmac} ->
            client_id =
              case entry.client_id && Ecto.UUID.cast(entry.client_id) do
                {:ok, valid} -> valid
                _ -> nil
              end

            cond do
              MapSet.member?(paths, hmac) ->
                {%{entry | result: {:error, %{path: ["duplicate path in batch"]}}}, {paths, ids}}

              client_id && MapSet.member?(ids, client_id) ->
                {%{entry | result: {:error, %{id: ["duplicate id in batch"]}}}, {paths, ids}}

              true ->
                ids = if client_id, do: MapSet.put(ids, client_id), else: ids
                {entry, {MapSet.put(paths, hmac), ids}}
            end

          other ->
            {other, {paths, ids}}
        end
      end)

    marked
  end

  defp run_batch_upsert(user, vault, entries) do
    pending = Enum.filter(entries, &is_nil(&1.result))
    hmacs = Enum.map(pending, & &1.path_hmac)

    existing_by_hmac =
      Repo.all(from(n in scoped_live(user, vault), where: n.path_hmac in ^hmacs))
      |> Map.new(&{&1.path_hmac, &1})

    # Delete-wins for the batch path (same blind spot as the single upsert):
    # an entry creating a note at a path tombstoned within the window with
    # identical content is a stale re-push racing an explicit delete. Mark it
    # as a per-note error so the delete stands, without aborting the batch.
    entries =
      mark_recently_deleted(entries, existing_by_hmac, recent_delete_twins(user, vault, hmacs))

    # vault_populated probe — must read BEFORE the insert_all below.
    was_empty =
      not Repo.exists?(scoped(user, vault))

    to_insert =
      Enum.count(
        entries,
        &(is_nil(&1.result) and not Map.has_key?(existing_by_hmac, &1.path_hmac))
      )

    check_batch_notes_cap!(user, to_insert)

    now = DateTime.utc_now()

    # One shared `now` for the whole batch — the seq feed orders by (seq, id),
    # so same-stamp runs are harmless.
    {entries, insert_rows} =
      Enum.map_reduce(entries, [], fn entry, rows ->
        process_batch_entry(entry, existing_by_hmac, user, vault, now, rows)
      end)

    # on_conflict: :nothing — a PK collision (client-supplied id already in
    # the DB, possibly cross-tenant) or a path-unique race degrades to a
    # per-note error below instead of aborting the whole batch with a raise.
    {entries, inserted_count} =
      case insert_rows do
        [] ->
          {entries, 0}

        rows ->
          # One op = one seq: every brand-new row in this batch shares it.
          seq = Engram.Vaults.next_seq!(vault.id)
          rows = Enum.map(Enum.reverse(rows), &Map.put(&1, :seq, seq))

          {_count, returned} =
            Repo.insert_all(Note, rows, on_conflict: :nothing, returning: [:id])

          inserted_ids = MapSet.new(returned, & &1.id)

          entries =
            Enum.map(entries, fn
              %{result: {:ok, %{prev_hash: nil, id: id}}} = entry ->
                if MapSet.member?(inserted_ids, id) do
                  entry
                else
                  %{entry | result: {:error, %{id: ["already exists"]}}}
                end

              entry ->
                entry
            end)

          {entries, MapSet.size(inserted_ids)}
      end

    if inserted_count > 0 do
      :ok = UsageMeters.inc_notes_count(user.id, inserted_count)
    end

    %{entries: entries, inserted_count: inserted_count, was_empty: was_empty, now: now}
  end

  # Mirrors the single-note cap check, scaled to the batch's insert count.
  # `check_limit/3` admits one insert when `current < limit`, so admitting N
  # inserts requires `current + N - 1 < limit`.
  defp check_batch_notes_cap!(_user, 0), do: :ok

  defp check_batch_notes_cap!(user, to_insert) do
    current_count = UsageMeters.notes_count(user.id)

    case Billing.check_limit(user, :notes_cap, current_count + to_insert - 1) do
      :ok ->
        :ok

      {:error, :limit_reached} ->
        limit = Billing.effective_limit(user, :notes_cap)
        Repo.rollback({:notes_cap_reached, limit, current_count})
    end
  end

  # A short, non-reversible handle for log lines. Base64 of the path HMAC,
  # truncated — enough to correlate two lines about the same note, useless for
  # recovering the path.
  #
  # binary_slice, not binary_part: the latter raises below 12 chars. Today the
  # HMAC is always SHA-256 (44 chars), but this sits INSIDE a rescue whose only
  # job is isolation, and a log helper must not be the thing that breaks it.
  defp hmac_ref(%{path_hmac: hmac}) when is_binary(hmac),
    do: hmac |> Base.encode64() |> binary_slice(0..11)

  defp hmac_ref(_entry), do: "unknown"

  defp process_batch_entry(%{result: nil} = entry, existing_by_hmac, user, vault, now, rows) do
    process_batch_entry_rescued(entry, rows, fn ->
      case Map.get(existing_by_hmac, entry.path_hmac) do
        nil ->
          case build_batch_insert_row(entry, user, vault, now) do
            {:ok, id, row, merged_text, content_hash} ->
              info = %{
                id: id,
                version: 1,
                prev_hash: nil,
                updated_at: now,
                content: merged_text,
                content_hash: content_hash,
                parse_status: row.parse_status,
                parse_reason: row.parse_reason
              }

              {%{entry | result: {:ok, info}}, [row | rows]}

            {:error, errors} ->
              {%{entry | result: {:error, errors}}, rows}
          end

        existing ->
          {%{entry | result: update_batch_entry(entry, existing, user)}, rows}
      end
    end)
  end

  defp process_batch_entry(entry, _existing_by_hmac, _user, _vault, _now, rows),
    do: {entry, rows}

  # Defense in depth (#task-6/#task-4): the known raise this guards
  # (frontmatter parsing) was already made impossible by the total codec in
  # Frontmatter (Task 1). This exists for whatever future parser/crypto/CRDT
  # call in `fun` raises next, and it cleanly isolates that raise to ONE entry
  # (per-note error result, siblings commit), including a raise that came
  # from a FAILED SQL STATEMENT, which a bare try/rescue could not contain.
  #
  # The batch runs each entry inside the SHARED Repo.with_tenant tx. Per-entry
  # SAVEPOINT isolation makes that total across both branches:
  #
  #   - CREATE branch (build_batch_insert_row): does zero per-entry DB
  #     writes (the insert_all runs AFTER the loop), so a raise here never
  #     touched the tx state at all.
  #   - UPDATE branch (update_batch_entry): next_seq! (UPDATE ... RETURNING)
  #     and Repo.update() run synchronously inside `fun`. If one of those SQL
  #     statements fails mid-tx, Postgres flips the whole tx into 25P02
  #     (in_failed_sql_transaction) and every SUBSEQUENT statement fails too.
  #     The batch UPDATE path runs both writes with `mode: :savepoint`
  #     (threaded via `db_mode: :savepoint` through do_update_note ->
  #     do_rewrite_note -> next_seq!/Repo.update), so a failed statement rolls
  #     back to its OWN savepoint and the outer tx stays healthy. query!/update
  #     still raise on failure, so this rescue degrades only THIS entry while
  #     siblings (and previously-succeeded entries) commit. No raise reachable
  #     via public input triggers this today (next_seq! only badmatches after a
  #     SUCCESSFUL roundtrip; the realistic path-unique race is caught by
  #     unique_constraint), but the guarantee no longer depends on that.
  #
  # NOTE: a bare nested `Repo.transaction` does NOT isolate a failed RAW query
  # (`Repo.query!`): DBConnection breaks the connection and disconnects. Only
  # `mode: :savepoint` on the failing operation recovers cleanly, which is why
  # the isolation lives on the DB writes, not around `fun`.
  #
  # `fun` is a thunk so this stays testable without a real reachable raise:
  # pass a fn that runs a real failing Repo query (a plain `raise` will NOT
  # exercise the savepoint, since it never enters 25P02).
  @doc false
  @spec process_batch_entry_rescued(map(), list(), (-> {map(), list()})) :: {map(), list()}
  def process_batch_entry_rescued(entry, rows, fun) do
    fun.()
  rescue
    e ->
      # The note ID, never the path. This used to interpolate `entry.path`
      # DELIBERATELY, to route it past the Sentry metadata allowlist so on-call
      # could see it — which is precisely the thing the allowlist exists to
      # prevent. RedactFilter and the Sentry scrubber both stop at metadata;
      # a message body is unfiltered, so that comment was describing a way
      # around the redaction rather than a reason to bypass it. A path is
      # folder structure plus a title, and Sentry is a third party.
      #
      # `Exception.message/1` is not "our own text": CaseClauseError,
      # MatchError, KeyError, Protocol.UndefinedError and Jason.EncodeError all
      # render `inspect(term)` of the offending value, and this rescue wraps
      # frontmatter parsing, CRDT merge and encryption — every one of which
      # handles note content. A raise over a note body printed the body:
      #
      #   batch entry raised ... (no case clause matching:
      #     {:parsed, "Dear diary, the biopsy came back positive."})
      #
      # Moving it to metadata does NOT fix that. `:error` is not in
      # RedactFilter's key set, so Loki and CloudWatch get it verbatim. (It is
      # absent from the Sentry metadata allowlist in application.ex, so Sentry
      # alone was safe — but "not sent to a third party" is not the bar; the
      # bar is not logged at all.)
      #
      # So the reason is filtered by exception TYPE, in both places. On-call
      # correlates on the path HMAC: non-reversible, joins to the same row.
      reason = Metadata.safe_reason(e)

      Logger.error(
        "batch entry raised, degrading note path_hmac=#{hmac_ref(entry)} (#{reason})",
        Metadata.with_category(:error, :sync,
          path: entry.path,
          error: reason
        )
      )

      {%{
         entry
         | result:
             {:error,
              %{
                "code" => "note_processing_failed",
                "message" => "This note could not be processed and was skipped.",
                "detail" => %{}
              }}
       }, rows}
  end

  defp update_batch_entry(entry, existing, user) do
    base_attrs = batch_base_attrs(entry, user)

    # db_mode: :savepoint isolates this entry's UPDATE-branch DB writes so a
    # failed SQL statement rolls back to a per-statement savepoint, leaving the
    # shared batch tx healthy for sibling entries (see process_batch_entry_rescued).
    case do_update_note(existing, base_attrs, user, entry.path, entry.folder, entry.tags,
           db_mode: :savepoint
         ) do
      {:ok, {prev_hash, updated, merged_text, content_hash}} ->
        {:ok,
         %{
           id: updated.id,
           version: updated.version,
           prev_hash: prev_hash,
           updated_at: updated.updated_at,
           content: merged_text,
           content_hash: content_hash,
           parse_status: updated.parse_status,
           parse_reason: updated.parse_reason
         }}

      {:error, changeset} ->
        {:error, changeset}

      # The batch calls do_update_note DIRECTLY — it never enters
      # lookup_and_write — so the bare `:stale_snapshot` atom surfaces here and
      # there is no retry above to absorb it. Without this clause the entry
      # raises CaseClauseError, which process_batch_entry_rescued swallows into
      # "note_processing_failed": no server_note, no 409, no retry, edit
      # silently dropped.
      #
      # `batch_upsert_results/2` already has a `{:conflict, existing}` clause
      # that hands back `server_note`, previously unreachable from the batch.
      # Map onto it so a draining offline queue can reconcile instead of
      # retrying the same stale content forever. #1335.
      :stale_snapshot ->
        {:conflict, existing}
    end
  end

  defp build_batch_insert_row(entry, user, vault, now) do
    note_id =
      case entry.client_id && Ecto.UUID.cast(entry.client_id) do
        {:ok, valid_uuid} -> valid_uuid
        _ -> mint_id()
      end

    base_attrs = batch_base_attrs(entry, user, vault)

    with {:ok, crdt} <- build_crdt_state(entry, user, note_id),
         # Finding 1 fix: move key derivation into the `with` head so a DEK
         # error propagates as {:error, _} rather than raising MatchError.
         {:ok, key} <- Crypto.dek_content_hash_key(user) do
      # Mirror the single-note insert path (upsert_note/3 ~line 441): derive
      # content, title, tags, and content_hash from the CRDT-projected text so
      # the DB row and the seeded doc are byte-for-byte consistent from birth.
      merged_tags = Helpers.extract_tags(crdt.merged_text)
      content_hash = Crypto.hmac_content_hash(key, crdt.merged_text)

      merged_attrs = %{
        base_attrs
        | content: crdt.merged_text,
          title: Helpers.extract_title(crdt.merged_text, entry.path),
          tags: merged_tags,
          content_hash: content_hash
      }

      crdt_row_fields = Map.take(crdt, [:crdt_state_ciphertext, :crdt_state_nonce])

      with {:ok, encrypted} <- Crypto.encrypt_note_fields(merged_attrs, user, note_id) do
        phase_b =
          inject_phase_b_fields(encrypted, user, note_id, entry.path, entry.folder, merged_tags)
          |> inject_okf_fields(user, note_id, crdt.merged_text)
          |> put_parse_status(crdt.merged_text)

        changeset = Note.changeset(%Note{id: note_id}, phase_b)

        if changeset.valid? do
          row =
            changeset
            |> Ecto.Changeset.apply_changes()
            |> Map.take(@batch_insert_columns)
            |> Map.merge(%{id: note_id, version: 1, created_at: now, updated_at: now})
            |> Map.merge(crdt_row_fields)

          # Finding 2 fix: return the PROJECTION hash so the digest can use the
          # stored value (not entry.hash which is HMAC of raw submitted content).
          {:ok, note_id, row, crdt.merged_text, content_hash}
        else
          {:error, changeset}
        end
      end
    end
  end

  defp build_crdt_state(entry, user, note_id) do
    content = entry.content || ""

    # merge_plaintext ingests via CrdtBridge.ingest_plaintext, which splits any
    # frontmatter fence out of the body into the Y.Map at insert time, so the
    # seeded state already satisfies the invariant. No normalize_doc is needed
    # on this path (unlike bind/3, which heals legacy at-rest state).
    with {:ok, %{state: state, text: merged_text}} <-
           CrdtBridge.merge_plaintext(nil, content),
         {:ok, {ct, nonce}} <- Crypto.encrypt_crdt_state(state, user, note_id) do
      {:ok, %{crdt_state_ciphertext: ct, crdt_state_nonce: nonce, merged_text: merged_text}}
    end
  end

  defp batch_base_attrs(entry, user, vault \\ nil) do
    attrs = %{
      kind: "note",
      content: entry.content,
      title: entry.title,
      tags: entry.tags,
      content_hash: entry.hash,
      mtime: entry.mtime,
      user_id: user.id
    }

    if vault, do: Map.put(attrs, :vault_id, vault.id), else: attrs
  end

  # Post-commit side effects: embed jobs (one Oban.insert_all), the digest
  # broadcast, FTUX vault_populated, and the per-creation funnel events.
  # Mirrors the single-note path; the digest replaces N note_changed events.
  defp batch_upsert_side_effects(user, vault, state) do
    ok_entries =
      Enum.filter(state.entries, fn
        %{result: {:ok, _}} -> true
        _ -> false
      end)

    embed_jobs =
      ok_entries
      |> Enum.filter(fn %{result: {:ok, info}} -> info.prev_hash != info.content_hash end)
      # clamp: false — Oban.insert_all ignores unique/replace, so the settle
      # ceiling is moot here; skip the per-note burst-start SELECT.
      |> Enum.map(fn %{result: {:ok, info}} ->
        EmbedNote.new_debounced(info.id, clamp: false)
      end)

    _ = if embed_jobs != [], do: Oban.insert_all(embed_jobs)

    # #648 lever 1 — same hash gate as embed_jobs; insert_all ignores
    # `unique`, but duplicate jobs converge under the Task 2 advisory lock
    # (same accepted posture as EmbedNote's `clamp: false` above).
    extract_jobs =
      ok_entries
      |> Enum.filter(fn %{result: {:ok, info}} -> info.prev_hash != info.content_hash end)
      |> Enum.map(fn %{result: {:ok, info}} -> ExtractNoteLinks.new_debounced(info.id) end)

    _ = if extract_jobs != [], do: Oban.insert_all(extract_jobs)

    # Same hash gate as the embed jobs: entries whose update short-circuited
    # (idempotent re-push, no version/seq persisted) must not appear in the
    # digest, or every batch re-sync fans a phantom change to all devices.
    # Compare projection-vs-projection (info.content_hash, the stored CRDT
    # projection) — NOT the raw entry hash. For frontmatter notes the
    # projection re-serializes YAML, so raw != projection on every push; a
    # raw-hash gate broadcasts a phantom digest for each idempotent re-push
    # of such notes (the exact syncedHashes re-pull loop Finding 2 fixed in
    # the digest body below).
    changed_entries =
      Enum.filter(ok_entries, fn %{result: {:ok, info}} ->
        info.prev_hash != info.content_hash
      end)

    _ =
      if changed_entries != [] do
        digest =
          Enum.map(changed_entries, fn %{result: {:ok, info}} = entry ->
            %{
              "event_type" => "upsert",
              "id" => info.id,
              "path" => entry.path,
              "title" => entry.title,
              "folder" => entry.folder,
              "tags" => entry.tags,
              "mtime" => entry.mtime,
              "version" => info.version,
              "updated_at" => info.updated_at,
              # Finding 2 fix: use the hash of the CRDT projection (stored row),
              # not entry.hash (HMAC of raw submitted content). For frontmatter
              # notes the projection re-serializes YAML so these diverge; using
              # entry.hash caused the plugin's syncedHashes to see a phantom
              # server change and re-pull on every batch push of tagged notes.
              "content_hash" => info.content_hash
            }
          end)

        _ =
          EngramWeb.Endpoint.broadcast("sync:#{user.id}:#{vault.id}", "notes.batch", %{
            op: "upsert",
            vault_id: vault.id,
            notes: digest,
            # Not routed through Broadcast.emit/3 (this dispatch predates the
            # per-item chokepoint), so stamp the traceparent directly. nil when
            # no span / OTEL off; clients skip a nil traceparent.
            traceparent: Engram.Observability.Otel.current_traceparent()
          })
      end

    created = Enum.filter(ok_entries, fn %{result: {:ok, info}} -> is_nil(info.prev_hash) end)

    _ =
      if state.was_empty and created != [] do
        EngramWeb.Endpoint.broadcast("user:#{user.id}", "vault_populated", %{
          vault_id: vault.id
        })
      end

    distinct_id = PostHog.distinct_id_for(user)

    Enum.each(created, fn _ ->
      :ok =
        PostHog.capture(distinct_id, "note_created", %{vault_id: vault.id})
    end)

    # Deliver-out to live CRDT rooms — without this, a room that has the note
    # open never sees the batch merge and its next checkpoint REVERTS it.
    Enum.each(ok_entries, fn %{result: {:ok, info}} = entry ->
      _ =
        CrdtDeliver.deliver_out(
          user.id,
          vault.id,
          entry.path,
          info.id,
          info.content
        )
    end)

    :ok
  end

  defp batch_upsert_results(user, entries) do
    Enum.map(entries, fn entry ->
      case entry.result do
        {:ok, info} ->
          %{
            path: entry.input_path,
            status: :ok,
            id: info.id,
            version: info.version,
            # The STORED hash (of the CRDT projection), matching the digest
            # broadcast — the raw submitted content's hash diverges for
            # frontmatter-bearing notes and would poison client syncedHashes.
            content_hash: info.content_hash,
            # Canonical (sanitized) path — differs from `path` when the
            # sanitizer rewrote the input; clients rename local files to it.
            server_path: entry.path,
            parse_status: info.parse_status,
            parse_reason: info.parse_reason
          }

        {:conflict, existing} ->
          %{
            path: entry.input_path,
            status: :conflict,
            server_note: decrypt_or_raise!(existing, user)
          }

        {:error, errors} ->
          %{path: entry.input_path, status: :error, errors: errors}
      end
    end)
  end

  # Resolve the note by id (ownership + cross-vault check) and delegate to
  # rename_note/4 with the recomposed path. rename_note takes the OLD path
  # string, sanitizes the new path, and pre-checks the unique
  # (user, vault, path_hmac) constraint, surfacing {:error, :conflict}
  # instead of crashing on a Postgrex unique_violation.
  defp move_note_into_folder(user, vault, id, target_folder) do
    # Meta fetch (#863): only note.path is needed to build the destination —
    # the previous get_note_by_id decrypted the full content per id, and
    # rename_note's inner path decrypts the row AGAIN for the re-encrypt.
    case fetch_note_by_id(user, vault, id, :meta) do
      {:ok, note} ->
        new_path =
          case target_folder do
            "" -> Path.basename(note.path)
            folder -> Path.join(folder, Path.basename(note.path))
          end

        case rename_note(user, vault, note.path, new_path) do
          {:ok, updated} -> {:ok, updated}
          {:error, :conflict} -> {:error, {:conflict, id}}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, {:not_found, id}}
    end
  end

  @changes_page_max_limit 500

  @doc """
  Seq-cursor change feed: rows with `(seq, id) > (after_seq, after_id)`,
  ordered by `(seq, id)`, paginated.

  Unlike the retired timestamp feed (`list_changes_page/4`, removed with
  `GET /notes/changes`) this carries the full note change set including
  tombstones (no `deleted_at` filter), so deletes and renames all flow
  through the unified seq-feed pull. Folder-marker
  rows (`kind == "folder"`) are EXCLUDED (#976): they carry `path: nil`,
  which crashed tombstone apply on pre-#216 plugins, and clients sync
  markers via the dedicated folder-marker endpoint, never this feed.
  Per-vault `seq` is monotonic and unique, so `(seq, id)` is a stable keyset
  that never loses or duplicates rows across pages.

  Options:

    * `after_id:` — the keyset tiebreak id from the previous page's `next`
      (the `id` component); required to resume mid-`seq`, harmless otherwise.
    * `limit:` — page size, clamped to 1..#{@changes_page_max_limit}
      (default #{@changes_page_max_limit}).
    * `fields: :meta` — skip the content column + its decrypt; entries carry
      `content_hash` and `content: nil`.

  Each change_map carries an extra `:seq` key. Returns
  `{:ok, %{changes: [...], has_more: bool, next: {seq, id} | nil}}`.
  """
  @spec list_changes_by_seq(map(), map(), integer(), keyword()) ::
          {:ok, %{changes: [map()], has_more: boolean(), next: {integer(), binary()} | nil}}
  def list_changes_by_seq(user, vault, after_seq, opts \\ []) when is_integer(after_seq) do
    limit =
      opts
      |> Keyword.get(:limit, @changes_page_max_limit)
      |> min(@changes_page_max_limit)
      |> max(1)

    fields = Keyword.get(opts, :fields, :all)
    after_id = Keyword.get(opts, :after_id)
    max_bytes = Keyword.get(opts, :max_bytes) || page_max_bytes()

    base =
      from(n in scoped(user, vault),
        where: not is_nil(n.seq) and n.kind != "folder",
        order_by: [asc: n.seq, asc: n.id],
        limit: ^(limit + 1)
      )

    base =
      if after_id do
        from(n in base, where: n.seq > ^after_seq or (n.seq == ^after_seq and n.id > ^after_id))
      else
        from(n in base, where: n.seq > ^after_seq)
      end

    query =
      case fields do
        :meta -> from(n in base, select: struct(n, @note_meta_fields))
        :all -> base
      end

    # Byte budget. `limit` caps ROWS; nothing capped BYTES, and POST /notes
    # accepts a 10 MB note — so a 500-row page could try to build ~5 GB inside
    # an 820 MB prod container, OOM the BEAM and take the ECS task down with
    # every other user on it.
    #
    # The probe runs as its own query because the budget has to bound the READ.
    # Trimming `notes` after Repo.all would already have transferred and (below)
    # decrypted the rows it was meant to exclude, which is exactly where the
    # memory goes. The probe selects sizes only — no content, no decrypt — so it
    # is a few KB regardless of how fat the page would have been.
    #
    # :meta carries no content, so it has no byte hazard and skips the probe.
    {row_limit, budget_more} =
      case {fields, max_bytes} do
        {:all, b} when is_integer(b) and b > 0 -> byte_budget_limit(base, user, limit, b)
        _ -> {limit + 1, false}
      end

    {:ok, notes} =
      Repo.with_tenant(user.id, fn -> Repo.all(from(q in query, limit: ^row_limit)) end)

    {page, has_more} =
      if length(notes) > limit do
        {Enum.take(notes, limit), true}
      else
        {notes, budget_more}
      end

    decrypted = decrypt_or_raise!(page, user)

    # #1339: `notes.content` is a FAÇADE that materializes at checkpoint, so a
    # note with uncheckpointed ops serves a body that lags — and when it lags
    # all the way to "", the client creates a 0-byte file and pushes the empty
    # hash back. Resolve the authority for exactly those notes, once per page.
    # Interleave point (tests only; the hook is nil everywhere else). A
    # checkpoint committing HERE — after the page SELECT, before resolution —
    # folds the tail into a new snapshot and prunes it. The resolution must
    # therefore re-read the row rather than trust what the page captured, or it
    # rebuilds from a pre-checkpoint snapshot with an empty tail and projects
    # "". See `notes_feed_interleave_test.exs`.
    interleave_hook(:feed_after_page_read)

    resolved = resolve_stale_page(user, decrypted, fields)

    changes =
      Enum.map(decrypted, fn note ->
        # The resolved row replaces the page's copy wholesale, so every field in
        # the emitted change comes from one coherent DB row — EXCEPT `seq`,
        # which stays the page's below because it is the cursor this page is
        # keyed on and moving it would break pagination. So a checkpoint landing
        # mid-page yields post-checkpoint content under a pre-checkpoint seq, and
        # the plugin fences CRDT rows by seq alone. Self-healing: the
        # checkpoint's new seq is above this page's max, so the row is
        # re-delivered on a later page.
        resolved_note = if fields == :all, do: Map.get(resolved, note.id, note), else: note

        resolved_note
        |> change_map(fields)
        |> Map.put(:seq, note.seq)
      end)

    # Second budget pass, on what the page ACTUALLY carries.
    #
    # The pre-read probe measures pg_column_size(content_ciphertext) — the
    # FAÇADE. `resolve_stale_page` then replaces that content with the body
    # rebuilt from the CRDT doc, and for the notes it exists to fix the façade is
    # "" while the entire body lives in the tail (genesis_insert_bare writes
    # content: ""). So the probe scores a genesis page at ~0 bytes, waves all 500
    # rows through, and resolution inflates them to their real size afterwards —
    # the exact page blow-up the budget exists to prevent, arriving by the one
    # route the probe cannot see. Not a corner case: it is #1339's primary shape.
    #
    # Resolution has already run by here, so this does not save that work (it is
    # chunked by @resolve_chunk, which bounds its own peak). What it bounds is
    # the frame — the Elixir term, its JSON encoding and the transport buffer,
    # which is where the multiple lives.
    {changes, has_more} = trim_to_budget(changes, has_more, fields, max_bytes)

    # Derived from `changes`, NOT `page`. The post-resolution trim can drop rows
    # that `page` still holds, and a cursor taken from `page` would then point
    # past them — the client resumes after rows it was never sent and they are
    # skipped permanently. Same shape as the merge watermark in Engram.Sync, one
    # layer down.
    next =
      if has_more do
        last = List.last(changes)
        if last, do: {last.seq, last.id}
      end

    {:ok, %{changes: changes, has_more: has_more, next: next}}
  end

  # Trim an already-built page to the byte budget, reporting whether anything
  # was dropped. Mirrors count_within_budget's first-row rule: one oversized
  # note ships alone rather than producing an empty page the feed can never
  # drain past.
  defp trim_to_budget(changes, has_more, :all, max_bytes)
       when is_integer(max_bytes) and max_bytes > 0 do
    kept =
      changes
      |> Enum.reduce_while({[], 0}, fn change, {acc, used} ->
        size = byte_size(change[:content] || "")

        cond do
          acc == [] -> {:cont, {[change], size}}
          used + size > max_bytes -> {:halt, {acc, used}}
          true -> {:cont, {[change | acc], used + size}}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    {kept, has_more or length(kept) < length(changes)}
  end

  defp trim_to_budget(changes, has_more, _fields, _max_bytes), do: {changes, has_more}

  # Default ceiling on the note content one catch-up page may carry. 4 MB keeps
  # a typical vault a single page (a 316-note real vault measured 1.5 MB) while
  # holding the worst case to ~4 MB per in-flight page instead of ~5 GB. The
  # frame is copied about three times on the way out (Elixir term, JSON string,
  # transport buffer), so the live cost is a small multiple of this, not this.
  @default_page_max_bytes 4 * 1024 * 1024

  defp page_max_bytes do
    Application.get_env(:engram, :sync_page_max_bytes, @default_page_max_bytes)
  end

  # How many of the next rows fit the byte budget, and whether the budget (not
  # the row limit) is what stopped the page.
  #
  # pg_column_size reads the stored size without detoasting the ciphertext, so
  # the probe stays cheap even when the rows it is measuring are huge. AES output
  # is incompressible, so for our data it tracks octet_length closely.
  defp byte_budget_limit(base, user, limit, max_bytes) do
    {:ok, sizes} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in base,
            select: fragment("coalesce(pg_column_size(?), 0)", n.content_ciphertext)
          )
        )
      end)

    fits = count_within_budget(sizes, max_bytes)
    {min(fits, limit + 1), fits <= limit and length(sizes) > fits}
  end

  defp count_within_budget(sizes, max_bytes) do
    sizes
    |> Enum.reduce_while({0, 0}, fn size, {n, acc} ->
      cond do
        # The first row always ships, however far over budget. A page of zero
        # rows with has_more is a feed that never drains: walkOpLog's
        # stuck-cursor guard breaks the loop and the note is stranded forever.
        # One oversized note should sync slowly, not block everything behind it.
        n == 0 -> {:cont, {1, size}}
        acc + size > max_bytes -> {:halt, {n, acc}}
        true -> {:cont, {n + 1, acc + size}}
      end
    end)
    |> elem(0)
  end

  # Resolves the authority for every note on this page whose façade lags,
  # returning %{note_id => note}. The value is the freshly-read row with
  # `content` replaced by the resolved body; `content_hash` is left as that row's
  # stored checkpoint hash, so the feed and `/sync/manifest` still agree. Notes
  # absent from the map keep their page row.
  #
  # `fields: :meta` never resolves: its projection does not even select
  # `crdt_state_ciphertext`, and it promises `content: nil` with the row's own
  # `content_hash`.
  defp resolve_stale_page(_user, _notes, :meta), do: %{}

  defp resolve_stale_page(user, notes, :all) do
    # Markdown only. `crdt_checkpoint.ex` refuses this exact projection for
    # structural docs: a `.canvas` keeps its data in Y.Maps, not the markdown
    # Y.Text, so `project_doc` returns "" and would replace the façade — the
    # only non-Yjs copy of the board — with an empty body under a matching hash.
    #
    # Tombstones are excluded in the same pass: they never prune their tail
    # (`delete_note/4` only sets deleted_at; the FK cascade is hard-delete
    # only), so a tombstone would be permanently "stale" — rebuilding a doc on
    # every page that carries it, and shipping a resurrected body on a
    # `deleted: true` row.
    candidates =
      Enum.filter(
        notes,
        &(&1.kind == "note" and markdown_path?(&1.path) and is_nil(&1.deleted_at))
      )

    case candidates do
      [] ->
        %{}

      candidates ->
        resolve_stale_candidates(user, candidates)
    end
  end

  # Resolution runs in chunks, each in its own transaction, and each chunk
  # re-reads its rows rather than trusting the page SELECT.
  #
  # It is NOT one snapshot: `Repo.with_tenant` is a plain transaction, so at READ
  # COMMITTED every statement takes its own. What makes the result stable is
  # holding the tail ROWS (fetched with the chunk, replayed from memory) instead
  # of re-querying them, plus degrading to the freshly-read row rather than the
  # page's copy.
  #
  # Both properties are load-bearing. `checkpoint_write` persists the new
  # snapshot and prunes the tail in one transaction, so with a page-captured
  # struct a checkpoint committing between the tail read and the rebuild leaves
  # `replay_tail` with nothing to replay AND a pre-checkpoint snapshot — which
  # for a genesis note whose body lives entirely in the tail projects "". With
  # the hash recomputed to match, the client would accept that as authoritative
  # and write a 0-byte file: #1339 again, through a narrower window. Reading
  # snapshot and tail together closes it.
  #
  # The single transaction also bounds the pool cost. `authoritative_content/2`
  # opens its own `with_tenant` per call, and a folder rename is exactly the
  # event that leaves MANY notes stale at once, so per-note resolution would be
  # hundreds of serial checkouts inside one channel `handle_in` — the shape
  # behind `docs/context/crdt-sync-pool-exhaustion-loop-2026-07-09.md`.
  #
  # ponytail: one query + N in-transaction rebuilds per page. When `content`
  # gains a `crdt_head`-style invalidate-on-write flag (BEFORE UPDATE trigger +
  # lazy self-heal), staleness becomes a column read and this collapses. See
  # `docs/context/worker-reads-stale-content-facade.md`.
  defp resolve_stale_candidates(user, candidates) do
    by_id = Map.new(candidates, &{&1.id, &1})

    by_id
    |> Map.keys()
    |> Enum.chunk_every(@resolve_chunk)
    |> Enum.reduce(%{}, fn chunk, acc -> Map.merge(acc, resolve_chunk(user, by_id, chunk)) end)
  end

  defp resolve_chunk(user, by_id, ids) do
    {:ok, {fresh_rows, tails}} =
      Repo.with_tenant(user.id, fn ->
        # Fetch the tail ROWS, not a count. Replaying from these buffers is what
        # makes the resolution race-free: `Repo.with_tenant` is a plain
        # transaction, so at READ COMMITTED each statement takes its own
        # snapshot, and re-querying the tail later would let a checkpoint prune
        # it between the fetch and the replay — leaving an empty replay against a
        # snapshot that predates the fold, which for a genesis note projects "".
        # Yjs updates are idempotent and commutative, so replaying rows a
        # checkpoint has since folded in is harmless. Holding them is strictly
        # safer than re-reading them, and it collapses one query per note into
        # one per chunk.
        tails =
          from(l in CrdtUpdateLog,
            where: l.note_id in ^ids,
            order_by: [asc: l.inserted_at]
          )
          |> Repo.all()
          |> Enum.group_by(& &1.note_id)

        # Re-read rows that still have a tail OR were captured with an empty
        # façade.
        #
        # The second group is the one an earlier cut missed. A checkpoint
        # committing between the page SELECT and here folds the tail into a new
        # snapshot, materializes the body back into `notes.content` and prunes
        # the tail — so the note stops looking stale, the resolution skips it,
        # and the page's captured façade stands. For a genesis note that façade
        # is "", which is #1339 exactly.
        #
        # This does re-read every genuinely-empty .md note on the page, not only
        # ones that raced a checkpoint — there is no cheaper test, since "was
        # this checkpointed since the SELECT?" is the question the re-read
        # answers. The bound is empty-façade notes, not all notes: a
        # page-captured NON-empty façade is real content at worst one checkpoint
        # old, so it is left alone.
        refresh_ids =
          for n <- ids,
              Map.has_key?(tails, n) or (by_id[n].content || "") == "",
              do: n

        {Repo.all(from(n in Note, where: n.id in ^refresh_ids)), tails}
      end)

    # Rebuild OUTSIDE the transaction. The race only requires that the note rows
    # and their tail rows be READ together; both are in memory now, and
    # `doc_from_state` + per-row AES decrypt + `Yex.apply_update` + `project_doc`
    # are pure NIF/CPU work with no DB access. Doing them inside would hold a
    # pooled connection across up to @resolve_chunk doc rebuilds on a channel
    # `handle_in` — with N devices in `crdt_catchup_since` at once, that is the
    # pool-exhaustion shape in
    # `docs/context/crdt-sync-pool-exhaustion-loop-2026-07-09.md`.
    raw_by_id = Map.new(fresh_rows, &{&1.id, &1})
    fresh_by_id = Map.new(decrypt_or_raise!(fresh_rows, user), &{&1.id, &1})

    Enum.reduce(Map.keys(raw_by_id), %{}, fn id, acc ->
      case Map.fetch(fresh_by_id, id) do
        {:ok, fresh} ->
          # Re-check the tombstone on the FRESH row: a delete committing between
          # the page SELECT and here would otherwise ship a resurrected body on
          # a `deleted: true` change, which the page-copy filter above cannot
          # see.
          if is_nil(fresh.deleted_at) do
            Map.put(acc, id, resolve_one(user, fresh, raw_by_id[id], Map.get(tails, id, [])))
          else
            acc
          end

        :error ->
          acc
      end
    end)
  end

  # Every path returns a NOTE — the freshly-read one, with `content` replaced by
  # the resolved body where there was one to resolve. Returning the whole row
  # rather than a {content, hash} pair keeps the emitted change coherent: an
  # earlier cut mixed a fresh body with the page's `version`/`updated_at`, so a
  # checkpoint landing mid-page made the feed serve newer bytes under an older
  # version, and the plugin's anti-stale guard (`known >= change.version`)
  # recorded a version that understated the content it held.
  defp resolve_one(user, fresh, row, tail_rows) do
    case Crypto.decrypt_crdt_state(row, user) do
      # `state` may be nil — a note that has never been checkpointed holds its
      # ENTIRE body in the tail (`genesis_insert_bare` writes content: "",
      # content_hash: nil, no snapshot). That is the primary #1339 shape, so
      # bailing here would serve "" for exactly the notes this exists to fix.
      # `doc_from_state(nil)` returns an empty doc and the tail fills it, which
      # is what `CrdtPersistence.bind/3` does on the write side.
      {:ok, state} ->
        project_resolved(user, fresh, row, state, tail_rows)

      # Degrade to the freshly-read row rather than fail the page. An earlier cut
      # raised here; that was wrong. The feed is keyset-ordered by seq, so one
      # note with an undecodable crdt_state fails identically on EVERY retry — it
      # would wedge the vault's catch-up permanently and crash
      # `crdt_catchup_since` into a rejoin loop. The row is the last good
      # checkpoint: stale, but real content the user wrote. The permanently
      # unreadable case has its own quarantine track in #959.
      {:error, reason} ->
        Logger.error(
          "feed: CRDT authority unreadable, serving last checkpoint",
          Metadata.with_category(:error, :sync,
            note_id: row.id,
            user_id: user.id,
            reason_label: inspect(reason)
          )
        )

        fresh
    end
  end

  defp project_resolved(user, fresh, row, state, tail_rows) do
    case CrdtBridge.doc_from_state(state) do
      {:ok, doc} ->
        applied = CrdtPersistence.apply_tail_rows(doc, user, row.id, tail_rows)
        text = CrdtBridge.project_doc(doc)

        cond do
          # A tail row that would not decrypt was logged and SKIPPED, so the
          # projection is missing ops — non-empty but truncated, which the
          # empty-projection guard below cannot see. A DEK fault mid-rotation
          # would otherwise ship a body with the newest edits missing.
          #
          # Race-free now that the rows are held rather than re-queried: a short
          # replay means a decrypt genuinely failed, not that a checkpoint pruned
          # the tail underneath us.
          length(applied) < length(tail_rows) ->
            Logger.warning(
              "feed: partial CRDT tail replay",
              Metadata.with_category(:warning, :sync,
                note_id: row.id,
                user_id: user.id,
                applied: length(applied),
                tail_rows: length(tail_rows)
              )
            )

            # Degrading to the row is only safe when the row HAS a body. A
            # never-checkpointed note has none — `genesis_insert_bare` leaves
            # content: "" and the whole body in the tail — so "serve the last
            # checkpoint" would serve "", and the client's discovery leg writes
            # that to disk and pushes the empty hash back. That is #1339, reached
            # through the one undecryptable tail row this branch exists for.
            # A truncated projection is strictly better: the room heals the
            # missing ops, and a 0-byte file does not.
            if (fresh.content || "") == "", do: %{fresh | content: text}, else: fresh

          # The read-side mirror of `ensure_projection_safe/2`. The write path
          # refuses to materialize "" over a façade that holds a body — "pure
          # data loss" in its own words — and the read path needs the same
          # backstop.
          text == "" and (fresh.content || "") != "" ->
            Logger.warning(
              "feed: CRDT projection is empty over a non-empty facade, serving the facade",
              Metadata.with_category(:warning, :sync, note_id: row.id, user_id: user.id)
            )

            fresh

          true ->
            %{fresh | content: text}
        end

      {:error, reason} ->
        Logger.error(
          "feed: CRDT doc rebuild failed, serving last checkpoint",
          Metadata.with_category(:error, :sync,
            note_id: row.id,
            user_id: user.id,
            reason_label: inspect(reason)
          )
        )

        fresh
    end
  end

  # Same rule `CrdtCheckpoint.markdown?/1` uses: only a `.md` note keeps its
  # body in the markdown Y.Text that `project_doc/1` reads.
  defp markdown_path?(path), do: is_binary(path) and String.ends_with?(path, ".md")

  # `fields: :meta` promises `content: nil` AND the row's `content_hash` — its
  # projection selects the hash on purpose, and a hash-free feed reads as "every
  # row diverged" to the client.
  defp change_map(note, fields) do
    %{
      id: note.id,
      path: note.path,
      title: note.title,
      folder: note.folder,
      tags: note.tags,
      version: note.version,
      mtime: note.mtime,
      content: if(fields == :meta, do: nil, else: note.content),
      content_hash: note.content_hash,
      deleted: not is_nil(note.deleted_at),
      updated_at: note.updated_at,
      parse_status: note.parse_status,
      parse_reason: note.parse_reason
    }
  end

  @doc """
  Returns unique tags across all non-deleted notes for a user.

  Phase B.3: tags live only in `tags_ciphertext` (envelope-encrypted JSON list).
  Each note's tags are decrypted Elixir-side and then deduplicated. Filters
  out notes with no tags via `tags_hmac != []` so we skip the decrypt round.
  """
  @spec list_tags(map(), map()) :: {:ok, [String.t()]}
  def list_tags(user, vault) do
    case Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Crypto.get_dek(user)

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where: not is_nil(n.tags_ciphertext) and n.tags_hmac != ^[],
                select: {n.id, n.dek_version, n.tags_ciphertext, n.tags_nonce}
              )
            )
          end)

        tags =
          rows
          |> Enum.flat_map(fn {id, dv, ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek, row_aad(:notes, :tags, id, dv))
            |> :erlang.binary_to_term([:safe])
          end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, tags}

      {:error, :no_dek} ->
        {:ok, []}
    end
  end

  @doc """
  Returns the unique OKF `type` values across all non-deleted notes for a user.

  Powers the type suggestions in the search filter panel. `type_hmac` is a
  blind index — it answers "does this note match?" but cannot be enumerated —
  so the inventory has to come from decrypting `type_ciphertext`, the same
  round-trip `list_tags/2` makes for tags.

  Values are normalised through `OkfFields.normalize_type/1` before dedup
  because the HMAC normalises before hashing: `Playbook` and `playbook` are
  ONE filter bucket, so offering both as separate suggestions would show two
  choices that return identical results.

  Unlike `list_tags/2`, this does NOT decrypt once per note. `type_hmac` is a
  deterministic hash of the normalised type, so distinct hmacs are exactly the
  distinct types — `DISTINCT ON` collapses to one representative row per type
  in the database (riding the existing `{user_id, vault_id, type_hmac}` index)
  and only those get decrypted. A 10k-note vault with a dozen types costs a
  dozen decrypts, not ten thousand. Tags cannot do this: `tags_hmac` is a
  list, so there is no one-row-per-value to collapse to.
  """
  @spec list_types(map(), map()) :: {:ok, [String.t()]}
  def list_types(user, vault) do
    case Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Crypto.get_dek(user)

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where: not is_nil(n.type_hmac) and not is_nil(n.type_ciphertext),
                distinct: [asc: n.type_hmac],
                select: {n.id, n.dek_version, n.type_ciphertext, n.type_nonce}
              )
            )
          end)

        # Enum.uniq/1 is NOT redundant after the DISTINCT ON. The hmac is keyed
        # by the user's filter key, so rows written either side of a filter-key
        # rotation carry different hmacs for the same logical type and survive
        # the database dedup as separate rows. Normalising and uniq'ing the
        # plaintext collapses them.
        types =
          rows
          |> Enum.map(fn {id, dv, ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek, row_aad(:notes, :type, id, dv))
            |> OkfFields.normalize_type()
          end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, types}

      {:error, :no_dek} ->
        {:ok, []}
    end
  end

  @doc """
  Returns unique non-empty folder paths for a user's notes.
  """
  @spec list_folders(map(), map()) :: {:ok, [String.t()]}
  def list_folders(user, vault) do
    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        {:ok, dek} = Crypto.get_dek(user)
        empty_hmac = Crypto.hmac_field(filter_key, "")

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where: not is_nil(n.folder_hmac) and n.folder_hmac != ^empty_hmac,
                distinct: n.folder_hmac,
                select: {n.id, n.dek_version, n.folder_ciphertext, n.folder_nonce}
              )
            )
          end)

        folders =
          rows
          |> Enum.map(fn {id, dv, ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek, row_aad(:notes, :folder, id, dv))
          end)
          |> Enum.sort()

        {:ok, folders}

      # No DEK = user has no encrypted data possible = no folders.
      {:error, :no_dek} ->
        {:ok, []}
    end
  end

  @doc """
  Returns just the explicit folder marker names (sorted, decrypted).
  Used by the plugin's GET /folders/explicit consumer to maintain its
  disk-side explicitFolders set. Derived folders (those inferred from
  notes living under a path) are excluded — only kind='folder' rows.
  """
  @spec list_explicit_folders(map(), map()) :: {:ok, [String.t()]}
  def list_explicit_folders(user, vault) do
    case Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Crypto.get_dek(user)

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where: n.kind == "folder",
                select: {n.id, n.dek_version, n.folder_ciphertext, n.folder_nonce}
              )
            )
          end)

        names =
          rows
          |> Enum.map(fn {id, dv, ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek, row_aad(:notes, :folder, id, dv))
          end)
          |> Enum.sort()

        {:ok, names}

      {:error, :no_dek} ->
        {:ok, []}
    end
  end

  @doc """
  Returns hydrated folder marker rows (kind="folder", non-deleted) for the
  user/vault, with `.folder` decrypted. Structs are sparsely loaded — only
  `.id`, `.folder` and `.folder_hmac` are populated (plus the decrypt
  inputs); callers needing other columns must fetch the row themselves. Used by
  Materialization to compute the existing-marker set and by the folders
  index for the path→id map (vs. `list_explicit_folders/2` which only
  returns sorted names).
  """
  @spec list_folder_markers(map(), map()) :: [Note.t()]
  def list_folder_markers(user, vault) do
    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      # Callers only consume `.id` + `.folder` (hydrated below) — project
      # just the decrypt inputs instead of full rows so a marker-heavy
      # vault doesn't pay for ~20 unused columns per row.
      {:ok, markers} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(
            from(n in scoped_live(user, vault),
              where: n.kind == "folder",
              select: %Note{
                id: n.id,
                dek_version: n.dek_version,
                folder_ciphertext: n.folder_ciphertext,
                folder_nonce: n.folder_nonce,
                folder_hmac: n.folder_hmac
              }
            )
          )
        end)

      Enum.map(markers, &hydrate_folder_marker(&1, dek))
    else
      {:error, :no_dek} -> []
    end
  end

  @doc """
  Folders with id/name/count/parent_id — the shape both `GET /folders`
  (FoldersController) and `GET /vault/tree` (VaultTreeController) return.
  Shared so the two never drift on parent-path semantics: root and
  top-level folders get `parent_id: nil`, never `""` — a `""` parent_id
  would make the root its own parent if a root marker ever exists, handing
  a cycle to the tree renderer.
  """
  @spec folders_payload(map(), map()) :: [map()]
  def folders_payload(user, vault) do
    {:ok, folders} = list_folders_with_counts(user, vault)
    markers = list_folder_markers(user, vault)
    id_by_path = Map.new(markers, fn m -> {m.folder, m.id} end)

    Enum.map(folders, fn f ->
      %{
        id: Map.get(id_by_path, f.folder),
        name: f.folder,
        count: f.count,
        parent_id: Map.get(id_by_path, folder_parent_path(f.folder))
      }
    end)
  end

  @doc """
  Every live `kind == "note"` row in a vault, with `id`, decrypted `path`,
  and both timestamps — the notes leg of `GET /vault/tree`
  (VaultTreeController). Folder markers are excluded: a marker's
  `path_ciphertext` is nil, and `PathCrypto.decrypt!/4` would raise on that
  regardless of what else is in the vault.

  Unlike `Attachments.list_attachments/2`, a row whose path fails AAD-bound
  decrypt is NOT skipped here — it raises. A note silently missing from the
  sidebar reads as data loss to the user, with no code path today that
  degrades a note listing gracefully (only attachments have that
  precedent); a loud 500 is the more honest failure for primary content,
  and the caller still has the per-folder fallback to fall back on. See PR
  #1316 review finding 3.
  """
  @spec list_tree_notes(map(), map()) :: {:ok, [map()]}
  def list_tree_notes(user, vault) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in scoped_live(user, vault),
            where: n.kind == "note",
            select:
              {n.id, n.dek_version, n.path_ciphertext, n.path_nonce, n.created_at, n.updated_at}
          )
        )
      end)

    {:ok, dek} = Crypto.get_dek(user)

    # Sequential on purpose — SyncController measured path-sized decrypts at
    # ~4µs each (10k in ~43ms) and found chunked parallel SLOWER, because
    # copying results back to the caller's heap rivals the AES-GCM work.
    notes =
      Crypto.measure_decrypt_batch(:vault_tree_notes, length(rows), fn ->
        Enum.map(rows, fn {id, dek_version, path_ct, path_nonce, created, updated} ->
          aad = PathCrypto.aad(:notes, id, dek_version)

          %{
            id: id,
            path: PathCrypto.decrypt!(path_ct, path_nonce, dek, aad),
            created_at: created,
            updated_at: updated
          }
        end)
      end)

    {:ok, notes}
  end

  # nil for top-level ("Projects") and root (""). Joined parent path for
  # nested ("Projects/Engram" -> "Projects").
  defp folder_parent_path(""), do: nil

  defp folder_parent_path(folder) do
    case folder |> String.split("/") |> Enum.drop(-1) do
      [] -> nil
      segments -> Enum.join(segments, "/")
    end
  end

  @doc """
  Returns the distinct set of cleartext folder paths *implied* by
  non-folder notes (kind="note") in this vault. Folder marker rows are
  intentionally excluded — this is the "where do notes live" view.
  Root ("") is excluded — only non-root parents are returned.

  Folder paths are encrypted at rest (Phase B.3), so this enumerates the
  distinct ciphertext rows and decrypts each. Batch-grade — intended for
  backfill workflows (`Notes.Materialization`), not per-request paths.
  """
  @spec list_folders_implied_by_notes(map(), map()) :: {:ok, [String.t()]}
  def list_folders_implied_by_notes(user, vault) do
    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        {:ok, dek} = Crypto.get_dek(user)
        empty_hmac = Crypto.hmac_field(filter_key, "")

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where:
                  n.kind == "note" and not is_nil(n.folder_hmac) and
                    n.folder_hmac != ^empty_hmac,
                distinct: n.folder_hmac,
                select: {n.id, n.dek_version, n.folder_ciphertext, n.folder_nonce}
              )
            )
          end)

        folders =
          Enum.map(rows, fn {id, dv, ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek, row_aad(:notes, :folder, id, dv))
          end)

        {:ok, folders}

      {:error, :no_dek} ->
        {:ok, []}
    end
  end

  @doc """
  Returns tags with counts across all non-deleted notes for a user.

  Phase B.3: tags are envelope-encrypted per note. Decrypts each note's
  tags Elixir-side, then aggregates counts. The Postgres `unnest()` /
  `GROUP BY tag` shortcut is gone with the plaintext column.
  """
  @spec list_tags_with_counts(map(), map()) :: {:ok, [%{name: String.t(), count: integer()}]}
  def list_tags_with_counts(user, vault) do
    case Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Crypto.get_dek(user)

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where: not is_nil(n.tags_ciphertext) and n.tags_hmac != ^[],
                select: {n.id, n.dek_version, n.tags_ciphertext, n.tags_nonce}
              )
            )
          end)

        counts =
          rows
          |> Enum.flat_map(fn {id, dv, ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek, row_aad(:notes, :tags, id, dv))
            |> :erlang.binary_to_term([:safe])
          end)
          |> Enum.frequencies()
          |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
          |> Enum.sort_by(& &1.name)

        {:ok, counts}

      {:error, :no_dek} ->
        {:ok, []}
    end
  end

  @doc """
  Returns folders with note counts for a user. Includes root folder (empty string).
  """
  @spec list_folders_with_counts(map(), map()) ::
          {:ok, [%{folder: String.t(), count: integer()}]}
  def list_folders_with_counts(user, vault) do
    case Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Crypto.get_dek(user)

        # Per folder_hmac, pick any one row (for envelope decryption) and
        # count only kind='note' rows. Marker-only folders yield count 0;
        # mixed folders yield the note count (markers excluded).
        #
        # The count MUST equal what `list_notes_in_folder/3` returns for the
        # same folder (both read kind='note' rows grouped by folder_hmac) — the
        # MCP `list_folders` vs `list_folder` contract (#728). Guarded by the
        # "invariant vs list_notes_in_folder/3 (#728)" tests in notes_test.exs.
        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where: not is_nil(n.folder_hmac),
                distinct: n.folder_hmac,
                select: %{
                  id: n.id,
                  dv: n.dek_version,
                  ct: n.folder_ciphertext,
                  nonce: n.folder_nonce,
                  count:
                    fragment(
                      "COUNT(*) FILTER (WHERE ? = 'note') OVER (PARTITION BY ?)",
                      n.kind,
                      n.folder_hmac
                    )
                }
              )
            )
          end)

        folders =
          rows
          |> Enum.map(fn %{id: id, dv: dv, ct: ct, nonce: nonce, count: count} ->
            %{
              folder: decrypt_envelope!(ct, nonce, dek, row_aad(:notes, :folder, id, dv)),
              count: count
            }
          end)
          |> Enum.sort_by(& &1.folder)

        {:ok, folders}

      {:error, :no_dek} ->
        {:ok, []}
    end
  end

  @doc """
  Returns all non-deleted notes in a specific folder for a user.
  Pass "" for root-level notes.
  """
  @spec list_notes_in_folder(map(), map(), String.t()) :: {:ok, [Note.t()]}
  def list_notes_in_folder(user, vault, folder) do
    # Phase B.2.6 — match by folder_hmac so the lookup survives B.3's drop of
    # the plaintext `folder` column. Both root ("") and named folders go
    # through the same HMAC equality check; the empty string has its own
    # well-defined HMAC.
    case Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        target_hmac = Crypto.hmac_field(filter_key, folder)

        # Metadata projection: every caller serializes summaries (path,
        # title, tags, ...) — content is never returned, so don't fetch
        # or decrypt it.
        {:ok, notes} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in scoped_live(user, vault),
                where: n.kind == "note" and n.folder_hmac == ^target_hmac,
                order_by: [asc: n.id],
                select: struct(n, @note_meta_fields)
              )
            )
          end)

        # Phase B.4: title is virtual — sort by decrypted title in BEAM
        # since SQL can't order by encrypted columns deterministically.
        decrypted = decrypt_or_raise!(notes, user)
        {:ok, Enum.sort_by(decrypted, & &1.title)}

      {:error, :no_dek} ->
        # Mirrors the list_folders (B.2.2) defensive empty: no DEK = no
        # encrypted notes possible = empty result.
        {:ok, []}
    end
  end

  @doc """
  Returns all non-deleted notes living directly under the folder identified
  by `marker_id` (a folder-marker row's id). Id-keyed counterpart to
  `list_notes_in_folder/3` — used by tree data loaders that already hold a
  marker id and shouldn't have to round-trip cleartext folder paths.

  Returns `{:error, :not_found}` when the id doesn't resolve to a live
  folder marker owned by `user`/`vault`.
  """
  @spec list_folder_notes_by_id(map(), map(), String.t()) ::
          {:ok, [Note.t()]} | {:error, :not_found}
  def list_folder_notes_by_id(user, vault, marker_id) when is_binary(marker_id) do
    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, marker} <- get_folder_marker_by_id(user, vault, marker_id),
         {:ok, dek} <- Crypto.get_dek(user) do
      hydrated = hydrate_folder_marker(marker, dek)
      list_notes_in_folder(user, vault, hydrated.folder)
    end
  end

  @spec get_folder_marker_by_id(map(), map(), String.t()) ::
          {:ok, Note.t()} | {:error, :not_found}
  defp get_folder_marker_by_id(user, vault, id) when is_binary(id) do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        case Repo.one(
               from(n in scoped_live(user, vault),
                 where: n.id == ^id and n.kind == "folder"
               )
             ) do
          nil -> {:error, :not_found}
          marker -> {:ok, marker}
        end
      end)

    result
  end

  @doc """
  Renames a folder and all notes within it (including subfolders).
  Rewrites path, folder, and title for each affected note.
  Returns {:ok, count} with the number of notes affected.
  """
  @spec rename_folder(map(), map(), String.t(), String.t()) ::
          {:ok, integer()} | {:error, :conflict | term()}
  def rename_folder(user, vault, old_folder, new_folder) do
    with {:ok, user} <- Crypto.ensure_user_dek(user) do
      rename_folder_gated(user, vault, old_folder, new_folder, nil)
    end
  end

  # Conflict-gated rename shared by the public entry point (rows = nil →
  # do_rename_folder scans the vault itself) and the batch-move path (rows =
  # the ONE decrypted scan shared across all K markers). Caller must have run
  # `Crypto.ensure_user_dek/1` already.
  defp rename_folder_gated(user, vault, old_folder, new_folder, rows) do
    new_folder = String.trim_trailing(new_folder, "/")
    old_prefix = old_folder <> "/"

    cond do
      # No-op rename: same folder. Skip the target conflict check so the
      # call is idempotent rather than colliding with itself.
      old_folder == new_folder ->
        do_rename_folder(user, vault, old_folder, old_prefix, new_folder, rows)

      folder_target_exists?(user, vault, new_folder) ->
        # Pre-check the unique (user, vault, path_hmac) constraint so
        # the caller gets {:error, :conflict} instead of a Postgrex
        # unique_violation crash deeper in the cascade. Matches by
        # folder_hmac (exact match on the immediate folder) — covers
        # the common case of renaming onto a populated folder or an
        # existing folder marker.
        {:error, :conflict}

      true ->
        do_rename_folder(user, vault, old_folder, old_prefix, new_folder, rows)
    end
  end

  # Phase B.3: plaintext `folder` is gone — match by folder_hmac. Returns
  # true if any non-deleted row (note or folder marker) lives directly in
  # `folder`. Used as the pre-check for rename_folder/4's conflict gate.
  #
  # NESTED-COLLISION GAP (intentional, documented):
  # This check only catches DIRECT-CHILD collisions — rows whose immediate
  # parent folder hashes to `target_hmac`. It does NOT catch nested
  # collisions like renaming `src` → `dst` where both `src/sub/x.md` and
  # `dst/sub/x.md` already exist. Those still surface as a
  # `Postgrex.Error{unique_violation, "notes_user_vault_path_hmac_v2"}`
  # from the cascade `update_all` in `do_rename_folder/5`.
  #
  # Why accepted: with opaque HMAC fields we can't do a prefix scan
  # (`WHERE folder LIKE 'dst/%'` is impossible on ciphertext+HMAC), and a
  # full decrypt-and-scan would be O(notes) for every rename. Defense in
  # depth for the nested case is deferred until we either index prefix
  # hashes or fold the check into the cascade transaction itself. The
  # common case (renaming onto a populated immediate folder or marker) is
  # caught here and returns `{:error, :conflict}` cleanly.
  #
  # Optimistic `{:ok, _} = dek_filter_key(user)` match: the only caller
  # (`rename_folder/4`) gates on `Crypto.ensure_user_dek/1` first, so
  # `:no_dek` is unreachable. Any other crypto failure (KMS down, provider
  # error) crashes loudly here rather than being silently masked.
  defp folder_target_exists?(user, vault, folder) do
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    target_hmac = Crypto.hmac_field(filter_key, folder)

    # Repo.with_tenant wraps the fn return in {:ok, _} (transaction).
    # Unwrap once so the caller can branch on a plain boolean.
    {:ok, exists?} =
      Repo.with_tenant(user.id, fn ->
        Repo.exists?(from(n in scoped_live(user, vault), where: n.folder_hmac == ^target_hmac))
      end)

    exists?
  end

  # Fetch + decrypt every live row in the vault for a folder-cascade scan
  # (Phase B.3: plaintext `folder` is gone, so prefix filtering happens in
  # Elixir over decrypted rows). Markers hydrate their single folder
  # envelope; real notes go through the parallel batch decryptor instead
  # of one-at-a-time. `:meta` skips the content column entirely for flows
  # that never rewrite content (delete cascades).
  # Always meta-projected (#863): both callers (folder rename + folder-delete
  # cascade) only need path/folder/kind; content decrypt is targeted per-id
  # where actually required (fetch_v1_contents).
  defp fetch_decrypted_live_rows(user, vault) do
    query = from(n in scoped_live(user, vault), select: struct(n, @note_meta_fields))

    {:ok, rows} = Repo.with_tenant(user.id, fn -> Repo.all(query) end)
    {:ok, dek} = Crypto.get_dek(user)

    # Marker rows have nil path_ciphertext, so the standard decrypt path
    # short-circuits before unwrapping the folder envelope — they go
    # through the dedicated hydrate path instead.
    {markers, real} = Enum.split_with(rows, &(&1.kind == "folder"))
    Enum.map(markers, &hydrate_folder_marker(&1, dek)) ++ decrypt_or_raise!(real, user)
  end

  # Targeted content fetch for legacy (pre-AAD) rows in a folder rename —
  # the only rows whose rename path re-encrypts content. Returns
  # %{note_id => plaintext content}; empty when the folder is all-v2.
  defp fetch_v1_contents(user, notes) do
    v1_ids =
      for n <- notes,
          n.kind == "note",
          n.dek_version != Crypto.row_version_aad_bound(),
          do: n.id

    fetch_note_contents(user, v1_ids)
  end

  # Fetch + decrypt the plaintext content for the given note ids.
  # Returns %{note_id => plaintext content}; empty for an empty id list.
  defp fetch_note_contents(_user, []), do: %{}

  defp fetch_note_contents(user, ids) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(n in Note, where: n.id in ^ids))
      end)

    rows
    |> decrypt_or_raise!(user)
    |> Map.new(fn n -> {n.id, n.content || ""} end)
  end

  # Per-class column sets for the folder-rename batch UPDATE. Each list MUST
  # equal the keys the matching kw builder returns (folder_only_aad_bound /
  # phase_b_path_folder_for / full_aad_bound_kw) — values are fetched from the
  # kw by these names when the VALUES rows are built.
  @marker_rename_cols [:folder_ciphertext, :folder_nonce, :folder_hmac]
  @v2_rename_cols [
    :path_ciphertext,
    :path_nonce,
    :path_hmac,
    :basename_hmac,
    :folder_ciphertext,
    :folder_nonce,
    :folder_hmac
  ]
  @v1_rename_cols [
    :content_ciphertext,
    :content_nonce,
    :title_ciphertext,
    :title_nonce,
    :path_ciphertext,
    :path_nonce,
    :path_hmac,
    :basename_hmac,
    :folder_ciphertext,
    :folder_nonce,
    :folder_hmac,
    :tags_ciphertext,
    :tags_nonce,
    :tags_hmac,
    :dek_version
  ]

  # Statement-size bound for the VALUES join: 500 rows × ≤16 params stays
  # well under Postgres's 65535-bind-param protocol limit.
  @rename_update_chunk 500

  defp do_rename_folder(user, vault, old_folder, old_prefix, new_folder, rows) do
    # :meta scan (#863 review): the v2 branch below never reads content —
    # a folder rename preserves the basename so the title can't change and
    # content/tags AADs key on note_id. Decrypting every content blob in
    # the vault kept rename O(vault-content-size); only legacy v1 rows
    # (full AAD rebind, needs content + recomputed title) fetch content,
    # targeted by id below. `rows` (batch-move path) reuses a scan the caller
    # already holds instead of re-scanning per marker.
    decrypted = rows || fetch_decrypted_live_rows(user, vault)

    notes =
      Enum.filter(decrypted, fn n ->
        n.folder == old_folder or String.starts_with?(n.folder || "", old_prefix)
      end)

    if notes == [] do
      {:ok, 0}
    else
      now = DateTime.utc_now()
      old_len = String.length(old_folder)
      content_by_id = fetch_v1_contents(user, notes)

      # Build bulk updates — compute new paths/folders/titles in Elixir,
      # then apply as a single update per note (avoids N+1 per-row queries).
      # Each tuple now carries the source note (decrypted) so the bulk loop
      # can re-encrypt content + tags with the row-id-bound AAD.
      #
      # Marker rows have no path/content/title to rewrite — only the
      # folder envelope. Carry nil new_path/new_title so the bulk loop
      # can branch on kind.
      updates =
        Enum.map(notes, fn note ->
          new_note_folder =
            if note.folder == old_folder do
              new_folder
            else
              new_folder <> String.slice(note.folder, old_len..-1//1)
            end

          {new_path, new_title} =
            case note.kind do
              "folder" ->
                {nil, nil}

              _ ->
                np =
                  new_note_folder <>
                    String.slice(note.path, String.length(note.folder)..-1//1)

                # Title recompute is only meaningful for the v1 full rebind;
                # v2 rows never rewrite the title (basename unchanged).
                title =
                  case Map.fetch(content_by_id, note.id) do
                    {:ok, content} -> Helpers.extract_title(content, np)
                    :error -> nil
                  end

                {np, title}
            end

          {note, note.path, new_path, new_note_folder, new_title}
        end)

      mtime_float = DateTime.to_unix(now) + 0.0

      real_note_updates =
        Enum.reject(updates, fn {note, _, _, _, _} -> note.kind == "folder" end)

      # One seq for the whole folder-rename op — shared across every touched
      # row (renamed updates + old-path tombstones). The cascade row-updates
      # AND the tombstone insert commit in a SINGLE transaction so a
      # cursor-based pull (`WHERE seq > cursor`) can never observe the renamed
      # rows at seq S, advance past S, and then miss the tombstones (also S,
      # excluded by `seq > cursor`) → lost delete / resurrection (#614).
      # seq is allocated inside the txn that holds the vault row lock; the
      # tombstone rows are built from in-memory data (no re-query of committed
      # state) so they fold cleanly into the same transaction.
      {:ok, _seq} =
        Repo.with_tenant(user.id, fn ->
          seq = Engram.Vaults.next_seq!(vault.id)

          # Batched write side: the old shape issued one update_all PER NOTE
          # (each row carries its own re-encrypted envelopes, so a plain
          # update_all can't express it). Partition rows by the column set
          # each class updates and apply each class as chunked
          # `UPDATE ... FROM (VALUES ...)` statements — column sets are
          # IDENTICAL to the old per-note set lists:
          #   markers → folder envelope only;
          #   AAD-bound v2 notes (#863) → path + folder envelopes only
          #     (content/tags AADs key on note_id and the basename can't
          #     change, so re-encrypting content was pure TOAST/WAL churn);
          #   legacy v1 rows → full rebind (the rename is their upgrade to
          #     AAD-bound encryption, dek_version stamped to 2).
          grouped =
            updates
            |> Enum.map(fn {note, _old_path, new_path, new_note_folder, new_title} ->
              case note.kind do
                "folder" ->
                  {ct, nonce, hmac} =
                    folder_only_aad_bound(user, note.id, new_note_folder, note.dek_version)

                  {:marker,
                   {note.id, [folder_ciphertext: ct, folder_nonce: nonce, folder_hmac: hmac]}}

                _ ->
                  if note.dek_version == Crypto.row_version_aad_bound() do
                    {:v2,
                     {note.id, phase_b_path_folder_for(user, note.id, new_path, new_note_folder)}}
                  else
                    {:v1,
                     {note.id,
                      full_aad_bound_kw(
                        user,
                        note.id,
                        Map.get(content_by_id, note.id, ""),
                        new_title,
                        new_path,
                        new_note_folder,
                        note.tags || []
                      )}}
                  end
              end
            end)
            |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

          # One shared `now` for every row this cascade writes — renamed rows
          # AND tombstones. The seq feed orders by (seq, id), so same-stamp
          # runs are harmless. `seq` stays IDENTICAL for every row — the #614
          # one-op-one-seq contract that keeps a cursor pull from splitting
          # the renamed rows from their tombstones.
          marker_rows = stamp_rename_rows(grouped[:marker] || [], now)
          v2_rows = stamp_rename_rows(grouped[:v2] || [], now)
          v1_rows = stamp_rename_rows(grouped[:v1] || [], now)

          bulk_rename_update!(marker_rows, @marker_rename_cols, seq)
          bulk_rename_update!(v2_rows, @v2_rename_cols, seq)
          bulk_rename_update!(v1_rows, @v1_rename_cols, seq)

          # Insert soft-deleted tombstones for old paths so the seq feed
          # (list_changes_by_seq — no deleted_at filter) carries delete
          # signals. Without these, catch-up clients retain stale files at
          # old paths after a folder rename. Tombstones
          # are full-row inserts so each must carry the encrypted
          # path/folder/tags fields too. Marker rows have no path to
          # tombstone — skip them. Built in-memory from `real_note_updates`,
          # stamped with the same `seq` and `now` as the renamed rows.
          tombstones =
            Enum.map(real_note_updates, fn {_note, old_path, _new_path, _new_folder, _title} ->
              # T3.6 — pre-allocate the tombstone id so the AAD bind string can
              # be constructed before insert. Tombstones are full-row inserts
              # written with empty content/title/tags but the row-id-bound AAD
              # still applies — keeps tombstones decryptable and indistinguishable
              # from any other AAD-bound row at read time.
              tomb_id = mint_id()
              old_path_folder = Helpers.extract_folder(old_path)

              full_kw =
                full_aad_bound_kw(user, tomb_id, "", "", old_path, old_path_folder, [])

              base = %{
                id: tomb_id,
                content_hash: "",
                mtime: mtime_float,
                user_id: user.id,
                vault_id: vault.id,
                created_at: now,
                updated_at: now,
                deleted_at: now,
                seq: seq
              }

              Map.merge(base, Map.new(full_kw))
            end)

          # Bind the insert_all return; it's no longer the block's tail
          # expression (the block returns `seq`), so discard explicitly to
          # satisfy Dialyzer's unmatched_return.
          _ = Repo.insert_all(Note, tombstones, on_conflict: :nothing)

          seq
        end)

      # Content for the upsert broadcast (e2e test_34 "received=yes
      # materialized=no"): the cascade scans meta columns only (#863), so the
      # `note` struct carries content: nil. Broadcasting that omits the inline
      # body, forcing receivers to wait ~30-60s for a pull to materialize the
      # renamed path. Decrypt each renamed note's body once here so the upsert
      # ships it inline, exactly like do_rename_note. Content is unchanged by a
      # rename, so the stored content_hash stays consistent with this body.
      # ponytail: decrypts every renamed note — a very large folder rename pays
      # O(content) here; accepted vs the pull-latency correctness bug.
      broadcast_contents =
        fetch_note_contents(user, Enum.map(real_note_updates, fn {n, _, _, _, _} -> n.id end))

      # Side effects outside the transaction — broadcast + reindex + link
      # rewrite fan-out. T3.2 — hmac-only args, never plaintext.
      # Marker rows have no path / no embedding / no basename, skip everything.
      Enum.each(real_note_updates, fn {note, old_note_path, new_path, new_note_folder, _title} ->
        old_path_hmac = old_path_hmac_b64!(user, old_note_path)

        _ =
          Enqueue.enqueue(
            Engram.Workers.RepathNoteIndex.new_debounced(note.id,
              old_path_hmac: old_path_hmac
            ),
            "repath_note_index"
          )

        # #648/#1231 Phase 3 — a folder rename is N note renames (basename
        # unchanged), so each moved note reuses the Phase 1 rewrite job
        # verbatim: qualified [[old-folder/…]] occurrences get the new
        # prefix; bare [[basename]] occurrences plan no edit (idempotence
        # guard in Rewriter.plan_edits/5). Old-path recovery = the tombstone
        # this very cascade inserted in the same transaction — no ciphertext
        # args. Origin safety is by construction: the plugin never calls the
        # folder-rename REST surface (it renames per-file over CRDT, which
        # Phase 2 gates), so every caller here is web/MCP and must rewrite.
        # Gated on a real move: the idempotent same-folder branch of
        # rename_folder_gated reaches this loop with old == new.
        _ =
          if old_note_path != new_path do
            Enqueue.enqueue(
              RewriteNoteLinks.new_for(
                user.id,
                vault.id,
                :note,
                note.id,
                old_path_hmac,
                Base.encode64(Links.basename_hmac(user, Links.basename_key(old_note_path)))
              ),
              "rewrite_note_links"
            )
          end

        # #976: carry the moved note's id on the old-path delete leg. The note
        # still exists (same id, new path, upsert leg below), so receivers can
        # correlate the delete+upsert pair by id instead of resolving by path
        # mid-relocation — the ambiguity window the resurrection bug lived in.
        #
        # Emit the new-path upsert BEFORE the old-path delete: the receiver
        # must relocate the note's id to the new path first, so the delete
        # reads as a relocation leg (id now lives elsewhere) instead of
        # tearing the note's CRDT room down by id before the new path can
        # materialize from it (e2e test_34 "received=yes materialized=no").
        #
        # Root cause of a dropped CRDT rebind on cross-tab folder rename: the
        # 4-arity clause below carries no `id`, so a client's id-keyed
        # `useNote(id)` cache never invalidates and its editor stays bound to
        # the pre-rename CRDT doc path. Pass the note (id included) through
        # the 6-arity clause instead, same as single-note rename does.
        :ok =
          broadcast_change(
            user.id,
            vault.id,
            "upsert",
            new_path,
            %{
              note
              | path: new_path,
                folder: new_note_folder,
                content: Map.get(broadcast_contents, note.id)
            },
            []
          )

        :ok = broadcast_change(user.id, vault.id, "delete", old_note_path, note.id, [])
      end)

      # #1231 — bulk rebind fan-out: ONE RebindNoteLinks per DISTINCT moved
      # basename (old and new basename keys are equal on a folder move, so
      # this is do_rename_note_inner's dedup-when-equal rule at folder
      # scale). Closes what the text rewrite can't: bare-link winners whose
      # shortest-path tiebreak flipped with the move, and pre-typed danglers
      # waiting on the NEW qualified path.
      real_note_updates
      |> Enum.filter(fn {_n, old_p, new_p, _f, _t} -> old_p != new_p end)
      |> Enum.map(fn {_n, old_p, _np, _f, _t} ->
        Links.basename_hmac(user, Links.basename_key(old_p))
      end)
      |> Enum.uniq()
      |> Enum.each(fn hmac ->
        _ = Enqueue.enqueue(RebindNoteLinks.new_for(user.id, vault.id, hmac), "rebind_note_links")
      end)

      {:ok, length(notes)}
    end
  end

  @doc """
  Soft-deletes a folder and every descendant (sub-markers and real notes).
  Mirrors `rename_folder/4`'s cascade shape: decrypts all live rows,
  filters by exact-match-or-prefix on `folder`, then bulk-updates
  `deleted_at` in one `update_all`.

  Returns `{:ok, %{deleted: count}}` where count is what was ACTUALLY
  soft-deleted: the folder marker (if present) plus every descendant note and
  sub-marker that still belonged to the folder at write time. Since #1346 a row
  that moved between the scan and the write is fenced out, so this can be lower
  than the scan matched — it is a count of removals, not of candidates. A folder
  that doesn't exist (no marker AND no notes underneath) returns
  `{:ok, %{deleted: 0}}` — same idempotency contract as `rename_folder/4`,
  which returns `{:ok, 0}` for an empty target.

  Side effects per real note:
  - Decrement usage meter.
  - Enqueue `DeleteNoteIndex` worker to clean up Qdrant points.
  - Broadcast `note_changed` with `event_type: "delete"`.

  Side effects per deleted marker (folder itself, and any sub-marker caught
  by the prefix scan): broadcast `note_changed` with `event_type: "delete"`
  and `path` set to the marker's own folder path. No index cleanup (markers
  carry no embedding). This is the empty-folder fix: without it, deleting a
  folder with no descendant notes emitted zero broadcasts and other clients
  never learned the folder was gone.

  PubSub disclosure: broadcasts are not transactional. A batch caller that
  composes this on top of `Repo.transaction` (see `batch_delete_folders/2`)
  will leak per-note and per-marker delete events for cascades that get
  rolled back. Same caveat as `batch_delete_notes/3`, the systemic fix
  (after-commit hooks) is tracked as a follow-up.
  """
  @spec delete_folder(map(), map(), String.t()) ::
          {:ok, %{deleted: non_neg_integer(), notes: non_neg_integer()}} | {:error, term()}
  def delete_folder(user, vault, folder) when is_binary(folder) do
    with {:ok, user} <- Crypto.ensure_user_dek(user) do
      do_delete_folder(user, vault, folder)
    end
  end

  defp do_delete_folder(user, vault, folder), do: do_delete_folders(user, vault, [folder])

  # Shared-scan cascade delete for one or more folders: ONE vault fetch
  # (metadata projection — deletes never touch content) + one parallel
  # batch decrypt + one update_all, regardless of how many folders the
  # batch names. Overlapping folders (parent + child in the same batch)
  # naturally dedupe through the union filter.
  defp do_delete_folders(user, vault, folders) do
    with {:ok, matches} <- scan_folders(user, vault, folders) do
      delete_scanned(user, vault, matches)
    end
  end

  @doc """
  One decrypt pass over the vault, returning the live rows under `folders` —
  the folder markers themselves plus every descendant, at any depth.

  Split out from the cascade so a caller that must DECIDE before deleting
  (`Engram.Folders.delete/4`'s emptiness guard) can count and then delete from
  the SAME row set. Counting via a separate scan cost a second full-vault
  fetch + batch decrypt per side, and left a window — under READ COMMITTED
  each statement takes its own snapshot — where a row committed between the
  count and the cascade was deleted without ever being counted. Handing the
  scanned rows straight to `delete_scanned/3` closes that gap outright: the
  guard now decides on exactly the rows that will be deleted.

  Returns `{:error, {:dek_unavailable, reason}}` rather than an empty list when
  the vault cannot be read — an unreadable vault is not an empty folder, and
  this feeds a delete guard.
  """
  @spec scan_folders(map(), map(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def scan_folders(user, vault, folders) do
    user = Crypto.fresh_user(user)

    case Crypto.get_dek(user) do
      {:ok, _dek} ->
        prefixes = Enum.map(folders, &(&1 <> "/"))

        {:ok,
         fetch_decrypted_live_rows(user, vault)
         |> Enum.filter(fn r ->
           f = r.folder || ""
           f in folders or Enum.any?(prefixes, &String.starts_with?(f, &1))
         end)}

      {:error, :no_dek} ->
        {:ok, []}

      {:error, reason} ->
        Logger.error(
          "folder scan: DEK unavailable, refusing to report contents",
          Metadata.with_category(:error, :crypto,
            user_id: user.id,
            vault_id: vault.id,
            folder_count: length(folders),
            reason: Crypto.format_dek_error(reason)
          )
        )

        {:error, {:dek_unavailable, Crypto.format_dek_error(reason)}}
    end
  end

  @doc """
  Soft-deletes rows produced by `scan_folders/3`, with the usual meter
  decrement, Qdrant cleanup enqueue and `note_changed` broadcasts.

  Re-asserts folder membership at write time (#1346), so a row that moved
  between the scan and here is skipped rather than deleted from a folder the
  caller never named. `:deleted` counts every row removed (notes + markers),
  `:notes` only the content notes — both measured from what the write actually
  touched, which is what the side effects here are driven from.
  """
  # No error branch: every failure inside is a raise, not a tuple.
  @spec delete_scanned(map(), map(), [map()]) ::
          {:ok, %{deleted: non_neg_integer(), notes: non_neg_integer()}}
  def delete_scanned(user, vault, matches) do
    # `Links.basename_hmac/2` below needs the DEK, and callers reach here with
    # the struct they started with — the same staleness `scan_folders/3`
    # reloads for. Reload rather than let a stale copy fail mid-cascade.
    user = Crypto.fresh_user(user)

    if matches == [] do
      {:ok, %{deleted: 0, notes: 0}}
    else
      now = DateTime.utc_now()

      {:ok, deleted_ids} =
        Repo.with_tenant(user.id, fn ->
          seq = Engram.Vaults.next_seq!(vault.id)

          # Chunked for the reason `@rename_update_chunk` already documents in
          # this module: each statement binds its rows' ids AND their folder
          # hmacs, so an unchunked delete of a deep tree walks into Postgres's
          # 65535-parameter ceiling — and carrying the hmac list moved that wall
          # closer than the id list alone did. Chunking `matches` rather than
          # `ids` keeps each statement's hmac list scoped to its own rows.
          deleted =
            matches
            |> Enum.chunk_every(@rename_update_chunk)
            |> Enum.reduce(MapSet.new(), fn chunk, acc ->
              {_updated, returned_ids} =
                chunk
                |> fenced_delete_query()
                |> Repo.update_all(set: [deleted_at: now, updated_at: now, seq: seq])

              MapSet.union(acc, MapSet.new(returned_ids))
            end)

          # Decrement only real notes — markers don't count against the meter.
          real_count =
            Enum.count(matches, fn r -> r.kind == "note" and MapSet.member?(deleted, r.id) end)

          if real_count > 0, do: :ok = UsageMeters.dec_notes_count(user.id, real_count)
          deleted
        end)

      log_fenced_skips(user, vault, matches, deleted_ids)

      {real_notes, markers} =
        matches
        |> Enum.filter(&MapSet.member?(deleted_ids, &1.id))
        |> Enum.split_with(fn r -> r.kind == "note" end)

      # Side effects outside the transaction context, so they never fire if
      # the update_all above rolled back. Qdrant cleanup + broadcasts.
      # Markers carry no embedding, so they skip the index-cleanup enqueue.
      Enum.each(real_notes, fn note ->
        # `note.path` is already decrypted (fetch_decrypted_live_rows above),
        # so the basename hmac for DeleteNoteIndex's chained rebind (#591) is
        # free here.
        _ =
          Enqueue.enqueue(
            delete_note_index_job(note, Links.basename_hmac(user, Links.basename_key(note.path))),
            "delete_note_index"
          )

        :ok = broadcast_change(user.id, vault.id, "delete", note.path, note.id, [])
      end)

      # Root cause of the empty-folder-lingers-in-tab-B bug: an empty folder's
      # cascade matches ONLY its own marker row (no descendant notes), so
      # skipping markers here left this branch with zero broadcasts. The web
      # client's note_changed handler invalidates the folders list on ANY
      # event regardless of path, so a minimal delete event carrying the
      # marker's own folder path is enough for other tabs to drop it. Same
      # emission style and position as the real-note loop above: after the
      # Repo.with_tenant transaction returns, so it never fires on rollback.
      Enum.each(markers, fn marker ->
        :ok = broadcast_change(user.id, vault.id, "delete", marker.folder, nil, [])
      end)

      # The counts the caller reports to the user. `length(matches)` was the
      # scanned set, which equals the deleted set only when nothing raced.
      # `:notes` excludes markers so `Folders.delete/4` can report content
      # notes without recounting a set it no longer owns.
      {:ok, %{deleted: MapSet.size(deleted_ids), notes: length(real_notes)}}
    end
  end

  # The fence skipping a row is the ONLY in-prod evidence that the #1346 race
  # is real, and the row it spares becomes a live note whose ancestor folder
  # markers were just deleted — an orphan, exactly the shape
  # `Folders.log_orphaned_attachments/4` refuses to let pass silently.
  #
  # Two distinct causes land here and the log does not try to tell them apart,
  # because the operator response is the same (look at the note, it is intact):
  #
  #   1. A move OUT of the tree — the case this fence exists for.
  #   2. A move deeper INSIDE the tree, into a folder created after the scan.
  #      The predicate is membership in the hmacs the scan OBSERVED, not "under
  #      the target prefix" — and it cannot be the latter, because `folder` is
  #      HMAC'd and SQL cannot prefix-match a keyed hash. So `Docs/a.md` moving
  #      to `Docs/new-sub/a.md` mid-delete is skipped even though it is still
  #      inside the tree the user asked to delete. Fail-safe (the note lives)
  #      and self-healing (a fresh scan sees it), but it is a real skip class.
  defp log_fenced_skips(user, vault, matches, deleted_ids) do
    skipped = Enum.reject(matches, &MapSet.member?(deleted_ids, &1.id))

    if skipped != [] do
      Logger.warning(
        "folder delete: membership fence skipped rows — they moved between scan and delete",
        Metadata.with_category(:warning, :sync,
          user_id: user.id,
          vault_id: vault.id,
          scanned: length(matches),
          deleted: MapSet.size(deleted_ids),
          skipped: length(skipped)
        )
      )
    end

    :ok
  end

  # The membership fence itself. `folder_hmac` is NOT NULL for both `kind`s by
  # check constraint (`notes_kind_shape_check`, validated in the empty-folders
  # phase-2 migration), so the hmac list can never contain a nil that would
  # silently drop a row from the match set.
  defp fenced_delete_query(chunk) do
    ids = Enum.map(chunk, & &1.id)
    hmacs = chunk |> Enum.map(& &1.folder_hmac) |> Enum.uniq()

    from(n in Note,
      where: n.id in ^ids and n.folder_hmac in ^hmacs and is_nil(n.deleted_at),
      select: n.id
    )
  end

  @doc """
  Atomic batch cascading delete for folder markers identified by id.

  For each id in `marker_ids`: resolves the folder marker (ownership-checked),
  decrypts its folder name, then runs `delete_folder/3` to soft-delete the
  marker plus every descendant. All-or-nothing: any missing/cross-vault id
  rolls the entire transaction back.

  Returns `{:ok, %{deleted: total}}` where `total` is the SUM of per-folder
  cascade counts (markers + real notes) across the batch. Returns
  `{:error, {:not_found, id}}` for the first missing or cross-vault id.

  Empty list short-circuits to `{:ok, %{deleted: 0}}` without opening a
  transaction.

  PubSub disclosure (same caveat as `batch_delete_notes/3`): `delete_folder/3`
  fires `note_changed` broadcasts per affected real note and marker inside the
  transaction. Subscribers may receive delete events for cascades that get rolled back when
  a later id in the batch fails. After-commit hooks are tracked as a follow-up.
  """
  @spec batch_delete_folders(map(), map(), [integer()]) ::
          {:ok, %{required(:deleted) => non_neg_integer(), optional(:folders) => [String.t()]}}
          | {:error, {:not_found, integer()} | term()}
  def batch_delete_folders(_user, _vault, []), do: {:ok, %{deleted: 0}}

  def batch_delete_folders(user, vault, marker_ids) when is_list(marker_ids) do
    Repo.transaction(fn ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, dek} <- Crypto.get_dek(user) do
        # Resolve every marker first (cheap indexed lookups), then run ONE
        # shared-scan cascade for all folders — the old per-id shape
        # re-fetched and re-decrypted the entire vault once per marker.
        marker_ids
        |> Enum.reduce_while([], fn id, acc ->
          case get_folder_marker_by_id(user, vault, id) do
            {:ok, marker} ->
              {:cont, [hydrate_folder_marker(marker, dek).folder | acc]}

            {:error, :not_found} ->
              {:halt, {:rollback, {:not_found, id}}}
          end
        end)
        |> case do
          {:rollback, reason} ->
            Repo.rollback(reason)

          folders ->
            # do_delete_folders/3 can now return {:error, {:dek_unavailable, _}}
            # (scan_folders re-checks the DEK, and a rotation can land between
            # this function's own get_dek and that one). Hard-matching turned
            # that into a MatchError + 500 instead of the clean rollback this
            # transaction is shaped to give.
            case do_delete_folders(user, vault, folders) do
              {:ok, %{deleted: n}} -> %{deleted: n, folders: folders}
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Atomic batch folder move. Each source folder marker in `marker_ids` is
  moved into the folder identified by `target_folder_id` (another marker's id).

  For each source: resolves the marker, computes the new folder path as
  `target_folder <> "/" <> Path.basename(source_folder)`, then delegates to
  `rename_folder/4` — which already cascades through descendants and
  re-encrypts path/folder/tags.

  All-or-nothing. Returns `{:ok, %{moved: n}}` on success (n = `length(marker_ids)`).
  Returns `{:error, {:not_found, id}}` for a missing/cross-vault source or for a
  missing target marker (with `id == target_folder_id`). Returns
  `{:error, {:conflict, id}}` when `rename_folder/4` rejects the destination
  (rows already present at the immediate target folder).

  Empty list short-circuits to `{:ok, %{moved: 0}}` without opening a
  transaction or resolving the target.

  PubSub disclosure: same caveat as `batch_move_notes/4`. `rename_folder/4`
  fires per-note broadcasts inside the transaction; rolled-back batches may
  leak events.
  """
  @spec batch_move_folders(map(), map(), [String.t()], String.t() | {:path, String.t()}) ::
          {:ok,
           %{
             required(:moved) => non_neg_integer(),
             optional(:pairs) => [{String.t(), String.t()}]
           }}
          | {:error, {:not_found | :conflict | :cycle, String.t()} | term()}
  def batch_move_folders(_user, _vault, [], _target_folder_id), do: {:ok, %{moved: 0}}

  # Move folders under a parent given by PATH. No marker is required at the
  # target — a "derived" parent exists purely as a path. `folder == ""` is root.
  def batch_move_folders(user, vault, marker_ids, {:path, folder})
      when is_list(marker_ids) and is_binary(folder) do
    Repo.transaction(fn ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, dek} <- Crypto.get_dek(user) do
        reduce_move_folders(user, vault, marker_ids, folder, dek)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def batch_move_folders(user, vault, marker_ids, "root") when is_list(marker_ids) do
    batch_move_folders(user, vault, marker_ids, {:path, ""})
  end

  def batch_move_folders(user, vault, marker_ids, target_folder_id)
      when is_list(marker_ids) and is_binary(target_folder_id) do
    Repo.transaction(fn ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, target_marker} <- get_folder_marker_by_id(user, vault, target_folder_id),
           {:ok, dek} <- Crypto.get_dek(user) do
        target_folder = hydrate_folder_marker(target_marker, dek).folder
        reduce_move_folders(user, vault, marker_ids, target_folder, dek)
      else
        {:error, :not_found} -> Repo.rollback({:not_found, target_folder_id})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Shared move loop (runs inside a transaction): move each marker under
  # `target_folder` (a path), rolling the whole batch back on the first failure.
  #
  # ONE shared vault scan for the whole batch (mirrors do_delete_folders/3) —
  # the old shape re-ran fetch_decrypted_live_rows (full-vault fetch + decrypt)
  # inside EVERY marker's rename cascade. The scan is advanced IN MEMORY after
  # each successful rename so a batch containing a parent and its own
  # descendant still filters against post-move state (the per-marker re-scan
  # got that for free by re-reading the DB inside the same transaction).
  defp reduce_move_folders(user, vault, marker_ids, target_folder, dek) do
    rows = fetch_decrypted_live_rows(user, vault)

    marker_ids
    |> Enum.reduce_while({%{moved: 0, pairs: []}, rows}, fn id, {acc, rows} ->
      case move_folder_into(user, vault, id, target_folder, dek, rows) do
        {:ok, {old_folder, new_folder}} ->
          acc = %{acc | moved: acc.moved + 1, pairs: [{old_folder, new_folder} | acc.pairs]}
          {:cont, {acc, advance_renamed_rows(rows, old_folder, new_folder)}}

        {:error, :not_found} ->
          {:halt, {:rollback, {:not_found, id}}}

        {:error, :conflict} ->
          {:halt, {:rollback, {:conflict, id}}}

        {:error, :cycle} ->
          {:halt, {:rollback, {:cycle, id}}}
      end
    end)
    |> case do
      {:rollback, reason} -> Repo.rollback(reason)
      {%{pairs: pairs} = acc, _rows} -> %{acc | pairs: Enum.reverse(pairs)}
    end
  end

  # In-memory mirror of what do_rename_folder/6 just committed, applied to the
  # shared batch scan: rows under `old_folder` get folder/path rewritten and
  # (real notes) dek_version bumped to AAD-bound — exactly the DB-visible
  # outcome — so the next marker in the batch sees current state without a
  # re-scan. Filter + rewrite arithmetic MUST match do_rename_folder/6.
  defp advance_renamed_rows(rows, old_folder, new_folder) do
    old_prefix = old_folder <> "/"
    old_len = String.length(old_folder)

    Enum.map(rows, fn n ->
      folder = n.folder || ""

      if folder == old_folder or String.starts_with?(folder, old_prefix) do
        new_note_folder =
          if folder == old_folder,
            do: new_folder,
            else: new_folder <> String.slice(folder, old_len..-1//1)

        new_path =
          case n.kind do
            "folder" -> n.path
            _ -> new_note_folder <> String.slice(n.path, String.length(folder)..-1//1)
          end

        dek_version =
          if n.kind == "note", do: Crypto.row_version_aad_bound(), else: n.dek_version

        %{n | folder: new_note_folder, path: new_path, dek_version: dek_version}
      else
        n
      end
    end)
  end

  # Resolve source marker → compute new folder under target → delegate to
  # the gated rename (which cascades through descendants, reusing the shared
  # batch scan). Mirrors move_note_into_folder/4's contract: returns {:ok, _}
  # or {:error, atom}.
  defp move_folder_into(user, vault, id, target_folder, dek, rows) do
    case get_folder_marker_by_id(user, vault, id) do
      {:ok, marker} ->
        source_folder = hydrate_folder_marker(marker, dek).folder

        # Cycle guard: moving a folder into itself or any descendant would
        # produce a path that's a strict suffix of the source, which both
        # `do_rename_folder/6`'s prefix scan can't reason about and is
        # semantically nonsense ("a" cannot live under "a/b"). Catch it
        # before the cascade runs so the caller gets a stable `:cycle`
        # signal instead of partial moves or a Postgrex crash.
        if target_folder == source_folder or
             String.starts_with?(target_folder, source_folder <> "/") do
          {:error, :cycle}
        else
          leaf = Path.basename(source_folder)

          new_folder =
            case target_folder do
              "" -> leaf
              tf -> tf <> "/" <> leaf
            end

          # rename_folder_gated's only error is :conflict — the batch entry
          # point already ran ensure_user_dek, so rename_folder/4's wider
          # error surface can't arise here (dialyzer proves the coverage).
          case rename_folder_gated(user, vault, source_folder, new_folder, rows) do
            {:ok, _count} -> {:ok, {source_folder, new_folder}}
            {:error, :conflict} -> {:error, :conflict}
          end
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # T3.2 helper — base64-encoded HMAC of a plaintext path under the user's
  # filter key. Used at Oban-enqueue boundaries so plaintext path / old_path
  # never enters `oban_jobs.args` JSONB. Raises on filter-key load failure
  # (Phase B.4 invariant: every authenticated request has a usable DEK).
  defp old_path_hmac_b64!(user, path) do
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    filter_key |> Crypto.hmac_field(path) |> Base.encode64()
  end

  # Phase B.3: decryption MUST raise on failure. Returning the un-decrypted
  # struct (with virtual path/folder/tags = nil) silently serializes
  # `{"path": null, "tags": []}` over a 200 OK and ships malformed sync events
  # to every connected device. Decrypt failure on persisted ciphertext means
  # real data corruption — surface it as a 5xx with a Sentry hit so operators
  # can intervene, never paper over it.
  defp decrypt_or_raise!(nil, _user), do: nil

  defp decrypt_or_raise!(%Note{} = note, user) do
    case Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, decrypted} ->
        decrypted

      {:error, reason} ->
        DecryptFailure.log("decrypt_failed", reason, user_id: user.id, note_id: note.id)

        raise "Phase B note decryption failed (user_id=#{user.id} " <>
                "note_id=#{note.id} error_kind=#{Telemetry.error_kind(reason)})"
    end
  end

  defp decrypt_or_raise!(notes, user) when is_list(notes) do
    notes
    |> Crypto.decrypt_notes_batch(user)
    |> Enum.zip(notes)
    |> Enum.map(fn
      {{:ok, decrypted}, _note} ->
        decrypted

      {{:error, reason}, note} ->
        DecryptFailure.log("decrypt_failed", reason, user_id: user.id, note_id: note.id)

        raise "Phase B note decryption failed (user_id=#{user.id} " <>
                "note_id=#{note.id} error_kind=#{Telemetry.error_kind(reason)})"
    end)
  end

  # Decrypts an envelope (ciphertext + nonce) with the user's DEK and the
  # supplied AAD. Raises if decryption fails — used in Phase B aggregations
  # where a failure means data corruption, not a recoverable condition.
  defp decrypt_envelope!(ct, nonce, dek, aad) do
    case Envelope.decrypt(ct, nonce, dek, aad) do
      {:ok, plaintext} -> plaintext
      :error -> raise "Phase B envelope decryption failed"
    end
  end

  # T3.6 — AAD constructor for aggregation queries that select raw
  # (id, dek_version, ct, nonce) tuples. Returns the row-id-bound AAD for
  # AAD-bound rows (v ≥ 2) and `<<>>` for legacy rows.
  defp row_aad(table, column, id, dek_version)
       when is_integer(dek_version) and dek_version >= 2 do
    Crypto.aad_for_row(table, column, id)
  end

  defp row_aad(_table, _column, _id, _dek_version), do: <<>>

  defp validate_path(nil),
    do:
      {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}

  defp validate_path(""),
    do:
      {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}

  defp validate_path(path), do: {:ok, path}

  defp content_hash(user, content) do
    with {:ok, key} <- Crypto.dek_content_hash_key(user) do
      {:ok, Crypto.hmac_content_hash(key, content)}
    end
  end

  @spec broadcast_change(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          Note.t(),
          keyword()
        ) ::
          :ok
  # Emits `vault_populated` only when this insert took the vault from 0
  # to 1 notes. Subsequent inserts skip the broadcast; the FTUX listener
  # is one-shot anyway, but avoiding extra channel traffic keeps the
  # invariant readable from the server side too.
  defp maybe_broadcast_vault_populated(user, vault) do
    # "Exactly one row?" via LIMIT 2 instead of COUNT(*): the aggregate
    # visits every matching row, so a bulk first-sync paid an O(vault)
    # count on every insert. The probe touches at most two index entries
    # regardless of vault size. Scope stays per-vault (NOT the per-user
    # usage_meters counter — multi-vault users must still get the event
    # for a new vault's first note).
    #
    # Predicates must MATCH `Vaults.do_content_counts/2` (`is_nil(deleted_at)`
    # and `kind == "note"`), because the page this event unblocks gates on
    # THAT counter. `scoped/2` alone counts folder markers and tombstones,
    # which live in this same table — and the plugin's catch-up seeds folder
    # rows BEFORE the first note, so any vault with one empty folder saw 2
    # rows here, skipped the broadcast, and left the web page spinning on a
    # `note_count` of 0 forever. Two "count the notes" predicates that
    # disagree is the bug; keep them identical.
    #
    # `skip_tenant_check:` rather than `Repo.with_tenant/2`: outside a
    # transaction that helper opens BEGIN + set_config + COMMIT, and this
    # runs on every genesis insert of a bulk first sync. The query already
    # filters user_id AND vault_id, so the tenant round-trip buys nothing.
    ids =
      Repo.all(
        from(n in scoped_live(user, vault), where: n.kind == "note", select: n.id, limit: 2),
        skip_tenant_check: true
      )

    _ =
      if length(ids) == 1 do
        EngramWeb.Endpoint.broadcast(
          "user:#{user.id}",
          "vault_populated",
          %{vault_id: vault.id}
        )
      end

    :ok
  end

  defp broadcast_change(user_id, vault_id, "upsert", path, %Note{} = note, opts) do
    # Protocol rev — dual-field transition: the payload carries BOTH
    # `content` and `content_hash` for one release. `content` is dropped the
    # release after the plugin min-version floor covers the hash-only
    # handler (self-host backends and plugins update on independent
    # cadences — do NOT remove early).
    # `note` here is normally either freshly written (upsert/batch scrub its
    # content) or loaded through Crypto.maybe_decrypt_note_fields (read-boundary
    # scrub), so its text fields are usually already valid UTF-8. The egress
    # scrub below is the last line of defense (#738): a caller that reaches this
    # site with unscrubbed content (a direct DB or CRDT write) would otherwise
    # ship invalid bytes that crash the V2 JSON serializer and take down PubSub.
    # `content: nil` means the row is meta-projected (the folder-rename
    # cascade reads meta columns only, #863) — the body exists but was never
    # loaded. Fabricating `""` here shipped an empty body next to the REAL
    # content_hash, and receivers materialized 0-byte files that then read
    # as converged forever (e2e test_34). Omit the key instead: the plugin's
    # hash-only branch fetches the body when `content` is absent.
    base = %{
      "event_type" => "upsert",
      "id" => note.id,
      "path" => path,
      "vault_id" => vault_id,
      "content_hash" => note.content_hash,
      "title" => note.title || "",
      "folder" => note.folder || "",
      "tags" => note.tags || [],
      "mtime" => note.mtime,
      "updated_at" => note.updated_at,
      "version" => note.version
    }

    base = if is_binary(note.content), do: Map.put(base, "content", note.content), else: base
    payload = Helpers.scrub_broadcast_payload(base)

    topic = "sync:#{user_id}:#{vault_id}"

    _ =
      case Keyword.get(opts, :broadcast_from) do
        pid when is_pid(pid) ->
          # `broadcast_from` excludes the pushing socket; it is never used from
          # the folder cascade (which has no socket to exclude), so it goes
          # straight through (not subject to deferral). Routed through Broadcast
          # so this socket-origin leg logs the same delivery breadcrumb.
          Broadcast.emit_from(pid, topic, "note_changed", payload)

        nil ->
          Broadcast.emit(topic, "note_changed", payload)
      end

    # Deliver-out to CRDT clients (gap ③): push the merged plaintext to a live
    # room's observers and announce the doc so clients lacking it pull. Runs
    # post-commit, best-effort. CRDT-origin writes never reach here (the
    # checkpoint writes the DB directly), so this fires solely for
    # REST/MCP/web/cascade writes — no double-delivery.
    _ = CrdtDeliver.deliver_out(user_id, vault_id, path, note.id, note.content || "")

    :ok
  end

  # `id` may be nil: only the folder-marker delete legitimately has no note
  # id to carry (it's a folder, not a note). Rename old-path "delete" legs
  # (single-note + folder cascade) DO carry the moved note's id since #976,
  # so receivers can correlate the delete+upsert pair as a relocation.
  # When a note is genuinely gone (delete_note/3, batch_delete_notes/3, the
  # folder-delete cascade's real-note loop), callers MUST pass the id: the web
  # client's useNote(id) cache is keyed by id, not path, since the URL-by-id
  # refactor, and only invalidates it `if payload.id !== undefined`. Omitting
  # id here left a currently-open deleted note's editor stuck showing stale
  # content forever in any OTHER tab watching the same note, never re-fetched,
  # never errored. See e2e "deleting the open note" test.
  @spec broadcast_change(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          Ecto.UUID.t() | nil,
          keyword()
        ) :: :ok
  defp broadcast_change(user_id, vault_id, event_type, path, id, opts) do
    payload = %{
      "event_type" => event_type,
      "path" => path,
      "vault_id" => vault_id,
      # Parity with the upsert branch, which has always carried "folder".
      # Receivers route a change to the right cached folder listing by this
      # field; omitting it forced every client to re-derive it from the path,
      # and the web app's re-derivation then had to map folder NAME -> folder
      # ID, where a derived folder's null id silently invalidated nothing (the
      # sidebar kept showing notes deleted from another device until reload).
      # The server already knows the folder — send it. Note this is parity for
      # NOTE changes only: attachments.ex builds its own note_changed payloads
      # and still omits the field (harmless — its consumers re-derive).
      "folder" => Helpers.extract_folder(path)
    }

    payload = if id, do: Map.put(payload, "id", id), else: payload

    # Origin attribution (#970): REST-driven changes have no socket pid to
    # exclude via broadcast_from, so the fanout reaches the very device that
    # made the change. Carrying the caller's X-Device-Id lets that device
    # drop its own echo (the 2026-07-08 replace-remote wipe applied its own
    # delete fanout and trashed the local vault).
    payload =
      case Keyword.get(opts, :origin_device_id) do
        device_id when is_binary(device_id) -> Map.put(payload, "device_id", device_id)
        _ -> payload
      end

    _ = Broadcast.emit("sync:#{user_id}:#{vault_id}", "note_changed", payload)

    :ok
  end

  # Phase B.1 dual-write — computes HMAC + envelope-encrypts each filterable field.
  # Returns the original attrs map merged with phase_b_* fields.
  # Callers MUST call ensure_user_dek/1 before invoking this helper.
  # If get_dek still fails after ensure, that is a real bug — raises rather
  # than silently skipping to enforce the "Phase B is mandatory" contract.
  # T3.6 — note_id is required to construct the AAD bind string for path /
  # folder / tags ciphertext.
  defp inject_phase_b_fields(attrs, user, note_id, path, folder, tags) do
    Map.merge(attrs, Map.new(phase_b_keyword_for(user, note_id, path, folder, tags)))
  end

  # OKF v0.1 fields. Sets ALL columns on every write: nil when the key is
  # absent, so removing frontmatter clears previously stored values.
  defp inject_okf_fields(attrs, user, note_id, content) do
    okf = OkfFields.extract(content)
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)

    type_hmac =
      case okf.type do
        nil -> nil
        t -> Crypto.hmac_field(filter_key, OkfFields.normalize_type(t))
      end

    attrs
    |> Map.merge(okf_envelope(dek, note_id, :type, okf.type))
    |> Map.merge(okf_envelope(dek, note_id, :description, okf.description))
    |> Map.merge(okf_envelope(dek, note_id, :resource, okf.resource))
    |> Map.merge(%{
      type_hmac: type_hmac,
      fm_timestamp: okf.fm_timestamp,
      fm_created: okf.fm_created
    })
  end

  defp okf_envelope(_dek, _note_id, field, nil) do
    {ciphertext_key, nonce_key} = okf_envelope_keys(field)
    %{ciphertext_key => nil, nonce_key => nil}
  end

  defp okf_envelope(dek, note_id, field, value) do
    {ct, nonce} = Envelope.encrypt(value, dek, Crypto.aad_for_row(:notes, field, note_id))
    {ciphertext_key, nonce_key} = okf_envelope_keys(field)
    %{ciphertext_key => ct, nonce_key => nonce}
  end

  # Explicit mapping instead of interpolated atoms (`:"#{field}_ciphertext"`)
  # so we never call binary_to_atom/2 at runtime; field is always one of the
  # three OKF fields below, so the atoms are already known at compile time.
  defp okf_envelope_keys(:type), do: {:type_ciphertext, :type_nonce}
  defp okf_envelope_keys(:description), do: {:description_ciphertext, :description_nonce}
  defp okf_envelope_keys(:resource), do: {:resource_ciphertext, :resource_nonce}

  @doc false
  # Public delegate so `CrdtCheckpoint` can reuse the single source of truth
  # for HMAC + envelope computation without duplicating the phase-B logic.
  # The `defp` counterpart cannot be called across module boundaries; this
  # thin wrapper exposes it without promoting it to an official public API.
  def inject_phase_b_fields_pub(attrs, user, note_id, path, folder, tags) do
    inject_phase_b_fields(attrs, user, note_id, path, folder, tags)
  end

  @doc false
  # Public delegate so `CrdtCheckpoint` can re-run OKF v0.1 frontmatter
  # extraction on every changed-text checkpoint, the same way it re-runs
  # Phase B. Without this, a live-editor frontmatter edit persists content
  # while type_ciphertext/type_hmac/fm_timestamp/fm_created keep stale
  # values. The `defp` counterpart cannot be called across module
  # boundaries; this thin wrapper exposes it without promoting it to an
  # official public API.
  def inject_okf_fields_pub(attrs, user, note_id, content) do
    inject_okf_fields(attrs, user, note_id, content)
  end

  # Frontmatter-resilience (Task 5): stamp parse_status/parse_reason from the
  # note's ACTUAL persisted content (the CRDT-merged text, same input
  # inject_okf_fields/4 uses at every call site), not the raw incoming push.
  # A clean re-write of a previously degraded note must reset both fields —
  # every call site re-derives from scratch rather than patching prior state,
  # so a fix silently self-heals on the next ingest.
  # ponytail: re-runs Frontmatter.split + parse on `content` that
  # inject_okf_fields/4 -> OkfFields.extract already parsed. Deliberately NOT
  # threaded: the block is tiny (microsecond parse) and threading would couple
  # OKF extraction to parse-status by changing extract/1's return contract and
  # this pipe's shape. Thread it only if this ever shows up on a profile.
  defp put_parse_status(attrs, content) do
    case Frontmatter.split(content) do
      {nil, _body} ->
        Map.merge(attrs, %{parse_status: "ok", parse_reason: nil})

      {block, _body} ->
        case Frontmatter.parse(block) do
          {:ok, _order, _values, []} ->
            Map.merge(attrs, %{parse_status: "ok", parse_reason: nil})

          {:ok, _order, _values, degraded} ->
            Map.merge(attrs, %{
              parse_status: "degraded",
              parse_reason: Frontmatter.reason_for(degraded)
            })

          :error ->
            Map.merge(attrs, %{
              parse_status: "degraded",
              parse_reason: Frontmatter.invalid_yaml_reason(block)
            })
        end
    end
  end

  # Returns a keyword list of Phase B field updates suitable for splicing into
  # `Repo.update_all(set: [...])` or `Repo.insert_all` rows. Single source of
  # truth for HMAC + envelope computation across upsert and rename paths.
  # Caller MUST have ensured the user has a DEK.
  #
  # Phase B.3: tags are always envelope-encrypted into tags_ciphertext +
  # tags_nonce regardless of vault.encrypted. Before B.3 the plaintext `tags`
  # column was the system of record for unencrypted vaults; that column is
  # now gone, so this helper is the only place tags get persisted.
  defp phase_b_keyword_for(user, note_id, path, folder, tags) when is_list(tags) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    tags_aad = Crypto.aad_for_row(:notes, :tags, note_id)

    {tags_ct, tags_n} =
      Envelope.encrypt(:erlang.term_to_binary(tags), dek, tags_aad)

    phase_b_path_folder_for(user, note_id, path, folder) ++
      [
        tags_ciphertext: tags_ct,
        tags_nonce: tags_n,
        tags_hmac: Enum.map(tags, &Crypto.hmac_field(filter_key, &1)),
        dek_version: Crypto.row_version_aad_bound()
      ]
  end

  # Marker-only rename helper. Re-encrypts JUST the folder envelope under the
  # row-id-bound AAD and recomputes the folder_hmac. Returns
  # `{ciphertext, nonce, hmac}` — caller splices into Repo.update_all `set:`.
  # No content/title/path/tags work because markers have none of those.
  defp rename_col_sql_type(:tags_hmac), do: "bytea[]"
  defp rename_col_sql_type(:dek_version), do: "integer"
  defp rename_col_sql_type(_col), do: "bytea"

  # Attaches the cascade's shared timestamp to each {id, kw} rename row,
  # producing the [{id, stamp, kw}] shape bulk_rename_update! consumes.
  defp stamp_rename_rows(rows, now) do
    Enum.map(rows, fn {id, kw} -> {id, now, kw} end)
  end

  # One `UPDATE notes ... FROM (VALUES ...)` per ≤500-row chunk. Every row in a
  # class gets DISTINCT ciphertexts, so this can't be a single update_all — but
  # it must not be one UPDATE per note either (the N+1 this replaces). Runs
  # inside the caller's with_tenant transaction: the RLS role restricts the raw
  # UPDATE to the tenant's rows, and the shared `seq` keeps the #614
  # one-op-one-seq contract. `rows` is [{note_id, stamp, kw}] where `kw`
  # holds a value for every column in `cols`. A nested-collision unique
  # violation raises Postgrex.Error exactly like the per-note update_all did.
  defp bulk_rename_update!([], _cols, _seq), do: :ok

  defp bulk_rename_update!(rows, cols, seq) do
    set_sql =
      Enum.map_join(cols, ", ", &"#{&1} = v.#{&1}") <> ", updated_at = v.updated_at, seq = $1"

    # id + updated_at + the class's columns, per VALUES row.
    ncols = length(cols) + 2

    rows
    |> Enum.chunk_every(@rename_update_chunk)
    |> Enum.each(fn chunk ->
      values_sql =
        chunk
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {_row, i} ->
          base = 2 + i * ncols

          col_placeholders =
            cols
            |> Enum.with_index(2)
            |> Enum.map_join(", ", fn {col, j} ->
              "$#{base + j}::#{rename_col_sql_type(col)}"
            end)

          "($#{base}::uuid, $#{base + 1}::timestamp, #{col_placeholders})"
        end)

      params =
        [seq] ++
          Enum.flat_map(chunk, fn {id, stamp, kw} ->
            [
              Ecto.UUID.dump!(id),
              DateTime.to_naive(stamp) | Enum.map(cols, &Keyword.fetch!(kw, &1))
            ]
          end)

      _ =
        Repo.query!(
          """
          UPDATE notes AS n
          SET #{set_sql}
          FROM (VALUES #{values_sql}) AS v(id, updated_at, #{Enum.join(cols, ", ")})
          WHERE n.id = v.id
          """,
          params
        )
    end)

    :ok
  end

  defp folder_only_aad_bound(user, row_id, folder, _dek_version) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)

    {ct, nonce} =
      Envelope.encrypt(folder, dek, Crypto.aad_for_row(:notes, :folder, row_id))

    {ct, nonce, Crypto.hmac_field(filter_key, folder)}
  end

  # T3.6 — full re-encrypt of every encrypted column on a note, with row-id
  # bound AAD on each. Returns a keyword list suitable for Repo.update_all
  # `set: ...` or struct! splicing. Stamps `dek_version=2` so the read path
  # picks up AAD-bound semantics for the whole row in one atomic update.
  defp full_aad_bound_kw(user, note_id, content, title, path, folder, tags) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)

    {content_ct, content_n} =
      Envelope.encrypt(
        content,
        dek,
        Crypto.aad_for_row(:notes, :content, note_id)
      )

    {title_ct, title_n} =
      Envelope.encrypt(
        title,
        dek,
        Crypto.aad_for_row(:notes, :title, note_id)
      )

    {path_ct, path_n} =
      Envelope.encrypt(
        path,
        dek,
        Crypto.aad_for_row(:notes, :path, note_id)
      )

    {folder_ct, folder_n} =
      Envelope.encrypt(
        folder,
        dek,
        Crypto.aad_for_row(:notes, :folder, note_id)
      )

    {tags_ct, tags_n} =
      Envelope.encrypt(
        :erlang.term_to_binary(tags || []),
        dek,
        Crypto.aad_for_row(:notes, :tags, note_id)
      )

    [
      content_ciphertext: content_ct,
      content_nonce: content_n,
      title_ciphertext: title_ct,
      title_nonce: title_n,
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Crypto.hmac_field(filter_key, path),
      basename_hmac: Crypto.hmac_field(filter_key, Links.basename_key(path)),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Crypto.hmac_field(filter_key, folder),
      tags_ciphertext: tags_ct,
      tags_nonce: tags_n,
      tags_hmac: Enum.map(tags || [], &Crypto.hmac_field(filter_key, &1)),
      dek_version: Crypto.row_version_aad_bound()
    ]
  end

  # Same as phase_b_keyword_for/5 but only re-keys path + folder. Used by
  # rename paths that don't change tags — preserves the existing tags_hmac /
  # tags_ciphertext on the row.
  defp phase_b_path_folder_for(user, note_id, path, folder) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    path_aad = Crypto.aad_for_row(:notes, :path, note_id)
    folder_aad = Crypto.aad_for_row(:notes, :folder, note_id)
    {path_ct, path_n} = Envelope.encrypt(path, dek, path_aad)
    {folder_ct, folder_n} = Envelope.encrypt(folder, dek, folder_aad)

    [
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Crypto.hmac_field(filter_key, path),
      basename_hmac: Crypto.hmac_field(filter_key, Links.basename_key(path)),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Crypto.hmac_field(filter_key, folder)
    ]
  end
end
