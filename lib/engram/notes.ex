defmodule Engram.Notes do
  @moduledoc """
  Notes context — CRUD for notes, folders, and tags.
  All operations are tenant-scoped via Repo.with_tenant/2.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Logger.DecryptFailure
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Chunk, Enqueue, Helpers, Note, PathSanitizer}
  alias Engram.Observability.PostHog
  alias Engram.Repo
  alias Engram.Telemetry
  alias Engram.UsageMeters
  alias Engram.Workers.{DeleteNoteIndex, EmbedNote}

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
    :updated_at
  ]

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
        from(n in Note,
          where:
            n.user_id == ^user.id and
              n.vault_id == ^vault.id and
              n.kind == "folder" and
              n.folder_hmac == ^folder_hmac
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
          case Repo.one(lookup_query) do
            nil ->
              insert_new_note(
                base_attrs,
                user,
                sanitized_path,
                folder,
                tags,
                client_id,
                lookup_query
              )

            existing ->
              do_update_note(existing, base_attrs, user, sanitized_path, folder, tags, opts)
          end
        end)

      case result do
        {:ok, {:ok, {prev_hash, note, _merged_text, _content_hash}}} ->
          _ =
            if prev_hash != note.content_hash do
              Enqueue.enqueue(EmbedNote.new_debounced(note.id), "embed_note")
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

    case Billing.check_limit(user, :notes_cap, current_count) do
      {:error, :limit_reached} ->
        # Free-tier launch §4.5 — carry the resolved limit + current count
        # back to the controller so the 402 body can populate them. The
        # resolver call here is the same one check_limit already made
        # internally; a second call is cheaper than threading the value out
        # of check_limit (no hot path).
        limit = Billing.effective_limit(user, :notes_cap)
        {:error, {:notes_cap_reached, limit, current_count}}

      :ok ->
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
            |> Map.put(:crdt_state_ciphertext, crdt.crdt_state_ciphertext)
            |> Map.put(:crdt_state_nonce, crdt.crdt_state_nonce)

          changeset = Note.changeset(%Note{id: note_id}, phase_b)

          seq = Engram.Vaults.next_seq!(base_attrs.vault_id)
          changeset = Ecto.Changeset.put_change(changeset, :seq, seq)

          # INSERT ... ON CONFLICT DO NOTHING on the live-note partial unique
          # index. A concurrent upsert of the same new path raced us — both saw
          # `nil` on the lookup above, so both reach here. A bare insert would
          # raise a `notes_user_vault_path_v2` unique violation that aborts the
          # whole tenant transaction (its trailing role-reset query then 25P02s
          # → controller 500), and the plugin's offline-queue flush treats a 500
          # as fatal (breaks the drain, flips offline) — the test_24 replay
          # flake. ON CONFLICT DO NOTHING no-ops the loser's insert at the SQL
          # level instead, leaving the transaction healthy. We then re-fetch and
          # compare ids to tell winner (we inserted our row) from loser (someone
          # else's row now occupies the path). No conflict_target — the only
          # unique index a kind="note" row can violate is notes_user_vault_path_v2;
          # a bare DO NOTHING (matching the insert_all sites elsewhere in this
          # module) sidesteps the partial-index conflict_target fragment-matching
          # footgun.
          case Repo.insert(changeset, on_conflict: :nothing) do
            {:ok, _} ->
              case Repo.one(lookup_query) do
                %Note{id: ^note_id} = inserted ->
                  :ok = UsageMeters.inc_notes_count(user.id, 1)
                  {:ok, {nil, inserted, crdt.merged_text, crdt.content_hash}}

                %Note{} = existing ->
                  # Concurrent create won; report a version conflict (→ 409) the
                  # client reconciles, exactly like a stale-version write.
                  {:conflict, existing}

                nil ->
                  {:error,
                   Ecto.Changeset.add_error(changeset, :path, "insert raced and vanished")}
              end

            {:error, changeset} ->
              {:error, changeset}
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
  defp do_update_note(existing, base_attrs, user, sanitized_path, folder, _tags, opts \\ []) do
    if is_binary(existing.content_hash) and
         existing.content_hash == base_attrs.content_hash and
         not Keyword.get(opts, :force, false) do
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
      {:ok, {existing.content_hash, existing}}
    else
      do_rewrite_note(existing, base_attrs, user, sanitized_path, folder)
    end
  end

  defp do_rewrite_note(existing, base_attrs, user, sanitized_path, folder) do
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
          |> Map.put(:crdt_state_ciphertext, crdt.crdt_state_ciphertext)
          |> Map.put(:crdt_state_nonce, crdt.crdt_state_nonce)

        seq = Engram.Vaults.next_seq!(existing.vault_id)

        existing
        |> Note.changeset(Map.put(phase_b, :version, existing.version + 1))
        |> Ecto.Changeset.put_change(:seq, seq)
        |> Repo.update()
        |> case do
          # Thread crdt.content_hash (HMAC of projection) alongside merged_text
          # so callers can include the stored hash in broadcast digests without
          # re-deriving it.
          {:ok, updated} ->
            {:ok, {existing.content_hash, updated, crdt.merged_text, crdt.content_hash}}

          {:error, changeset} ->
            {:error, changeset}
        end
      end
    end
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
          Engram.Notes.CrdtBridge.merge_plaintext(nil, incoming_content)

        is_nil(prior_state) ->
          # Pre-CRDT note (existing %Note{} with nil crdt_state columns): tail
          # rows MAY exist (bind/3 seeds the full text into the tail-log before
          # any checkpoint). Replay the tail, then two-way-diff the incoming
          # text against the tail-inclusive doc to avoid full-body duplication.
          with {:ok, doc} <- Engram.Notes.CrdtBridge.doc_from_state(nil) do
            _count = Engram.Notes.CrdtPersistence.replay_tail(doc, user, note_id)
            Engram.Notes.CrdtBridge.merge_plaintext_into_doc(doc, incoming_content)
          end

        true ->
          # Two independent docs from the same snapshot:
          # - snapshot_doc: the shared ancestor; the incoming diff is applied here to
          #   capture the minimal Yjs operations that encode the incoming change.
          # - tail_doc: snapshot + replayed tail; the captured incoming operations are
          #   applied here so Yjs merges them convergently with the tail operations.
          with {:ok, snapshot_doc} <- Engram.Notes.CrdtBridge.doc_from_state(prior_state),
               {:ok, tail_doc} <- Engram.Notes.CrdtBridge.doc_from_state(prior_state) do
            # Fold in updates logged since the last checkpoint. Runs inside the
            # caller's with_tenant txn — no nested tenant context needed.
            _count = Engram.Notes.CrdtPersistence.replay_tail(tail_doc, user, note_id)

            Engram.Notes.CrdtBridge.merge_plaintext_relative_to_snapshot(
              snapshot_doc,
              tail_doc,
              incoming_content
            )
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
  Returns the note at `path`, creating an empty one if it doesn't exist yet.

  Used by the CRDT channel's self-bootstrap: a brand-new note arrives as a CRDT
  update before any REST row exists, so the row must be created on first
  reference (the incoming update populates the body, materialized on checkpoint).
  Without this a note could never be created over the CRDT path (chicken-and-egg).
  """
  @spec get_or_bootstrap_note(map(), map(), String.t()) ::
          {:ok, Note.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :version_conflict, Note.t()}
          | {:error, {:notes_cap_reached, non_neg_integer(), non_neg_integer()}}
          | {:error, atom()}
  def get_or_bootstrap_note(user, vault, path) do
    # Sanitize FIRST so the lookup keys on the SAME path upsert_note persists
    # under. The CRDT wire doc_id keeps the raw (possibly dirty) path, but the
    # note is stored at the sanitized path. Without sanitizing here, get_note for
    # a dirty path never matches the stored note, so every crdt_msg re-bootstraps
    # via upsert_note(content: "") and repeatedly wipes the body — the note never
    # materializes at the clean path (see e2e tests/crdt illegal-path test).
    sanitized = PathSanitizer.sanitize(path)

    case get_note(user, vault, sanitized) do
      {:ok, note} -> {:ok, note}
      {:error, :not_found} -> upsert_note(user, vault, %{"path" => sanitized, "content" => ""})
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
    with {:ok, user} <- Crypto.ensure_user_dek(user) do
      {:ok, result} =
        Repo.with_tenant(user.id, fn ->
          case Repo.get(Note, id) do
            %Note{user_id: uid, vault_id: vid, deleted_at: nil} = note
            when uid == user.id and vid == vault.id ->
              {:ok, decrypt_or_raise!(note, user)}

            _ ->
              {:error, :not_found}
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

      {:ok,
       from(n in Note,
         where:
           n.user_id == ^user.id and n.vault_id == ^vault.id and n.path_hmac == ^hmac and
             is_nil(n.deleted_at)
       )}
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
            case Repo.one(lookup_query) do
              nil -> :not_found
              note -> do_rename_note_inner(note, user, new_path, new_folder, now)
            end
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

        :ok = broadcast_change(user.id, vault.id, "delete", old_path)
        decrypted = decrypt_or_raise!(note, user)
        :ok = broadcast_change(user.id, vault.id, "upsert", note.path, decrypted)
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

    {count, _} =
      from(n in Note, where: n.id == ^note.id)
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
      :not_found
    end
  end

  @doc """
  Soft-deletes a note. Idempotent — returns :ok even if note doesn't exist.
  Also cleans up Qdrant points and chunk records for the deleted note.
  """
  @spec delete_note(map(), map(), String.t()) :: :ok
  def delete_note(user, vault, path) do
    now = DateTime.utc_now()

    note =
      case find_note_by_path(user, vault, path) do
        {:ok, note} -> note
        _ -> nil
      end

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

        # T3.2 — pass path_hmac (base64), never plaintext path. The note row
        # already carries `path_hmac` raw bytes; base64-encode for JSON safety.
        Enqueue.enqueue(
          DeleteNoteIndex.new(%{
            note_id: note.id,
            user_id: note.user_id,
            vault_id: note.vault_id,
            path_hmac: Base.encode64(note.path_hmac)
          }),
          "delete_note_index"
        )
      end

    broadcast_change(user.id, vault.id, "delete", path)
  end

  @doc """
  Soft-deletes a note by its primary key id, scoped to the given user + vault.

  Returns `:ok` on success, `{:error, :not_found}` when the id doesn't resolve
  to a live note owned by the caller (unlike `delete_note/3` which is
  idempotent — callers of URL-by-id endpoints want a hard 404 signal).

  Delegates to `delete_note/3` once ownership is verified, so Qdrant cleanup +
  usage-meter decrement + `note_changed` broadcast all run as a side-effect.
  """
  @spec delete_note_by_id(Engram.Accounts.User.t(), map(), String.t()) ::
          :ok | {:error, :not_found}
  def delete_note_by_id(user, vault, id) when is_binary(id) do
    case get_note_by_id(user, vault, id) do
      {:ok, note} -> delete_note(user, vault, note.path)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Atomically soft-deletes a list of notes by id, scoped to the caller's
  user + vault. All-or-nothing: if any id fails to resolve to a live note
  owned by the caller, the entire batch rolls back and no notes are
  deleted.

  Returns `{:ok, %{deleted: n}}` on success (n = `length(ids)`), or
  `{:error, {:not_found, id}}` identifying the first offending id when
  one or more ids don't resolve.

  Empty list short-circuits to `{:ok, %{deleted: 0}}` without opening a
  transaction. Composed on top of `delete_note_by_id/3` — each per-id
  delete runs inside the outer `Repo.transaction`, so a later `:not_found`
  reverts prior successful deletes (Qdrant/Oban side-effects enqueued
  during the rolled-back transaction are still inserted via Oban's
  `Repo.insert`, but only become visible after commit; on rollback they
  vanish with the transaction).

  Note: `delete_note/3` fires a `note_changed` event via `Phoenix.PubSub`
  during each per-id iteration. PubSub broadcasts are NOT transactional —
  subscribers may receive events for items that ultimately get rolled back
  when a later id in the batch fails. This is consistent with the
  single-target delete behavior and acceptable because the typical batch
  caller (the same client that initiated the batch) sees the synchronous
  `{:error, _}` return value and can reconcile. The systemic fix
  (after-commit hooks so broadcasts only fire post-commit) is tracked as a
  follow-up issue and will land before more batch ops are added.
  """
  @spec batch_delete_notes(map(), map(), [integer()]) ::
          {:ok, %{deleted: non_neg_integer()}}
          | {:error, {:not_found, integer()} | term()}
  def batch_delete_notes(_user, _vault, []), do: {:ok, %{deleted: 0}}

  def batch_delete_notes(user, vault, ids) when is_list(ids) do
    Repo.transaction(fn ->
      Enum.reduce_while(ids, %{deleted: 0}, fn id, acc ->
        case delete_note_by_id(user, vault, id) do
          :ok -> {:cont, Map.update!(acc, :deleted, &(&1 + 1))}
          {:error, :not_found} -> {:halt, {:rollback, {:not_found, id}}}
        end
      end)
      |> case do
        {:rollback, reason} -> Repo.rollback(reason)
        acc -> acc
      end
    end)
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
    :folder_ciphertext,
    :folder_nonce,
    :folder_hmac,
    :tags_hmac
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
      Repo.all(
        from(n in Note,
          where:
            n.user_id == ^user.id and n.vault_id == ^vault.id and n.path_hmac in ^hmacs and
              is_nil(n.deleted_at)
        )
      )
      |> Map.new(&{&1.path_hmac, &1})

    # vault_populated probe — must read BEFORE the insert_all below.
    was_empty =
      not Repo.exists?(from(n in Note, where: n.user_id == ^user.id and n.vault_id == ^vault.id))

    to_insert =
      Enum.count(pending, &(not Map.has_key?(existing_by_hmac, &1.path_hmac)))

    check_batch_notes_cap!(user, to_insert)

    now = DateTime.utc_now()

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

  defp process_batch_entry(%{result: nil} = entry, existing_by_hmac, user, vault, now, rows) do
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
              content_hash: content_hash
            }

            {%{entry | result: {:ok, info}}, [row | rows]}

          {:error, errors} ->
            {%{entry | result: {:error, errors}}, rows}
        end

      existing ->
        {%{entry | result: update_batch_entry(entry, existing, user)}, rows}
    end
  end

  defp process_batch_entry(entry, _existing_by_hmac, _user, _vault, _now, rows),
    do: {entry, rows}

  defp update_batch_entry(entry, existing, user) do
    base_attrs = batch_base_attrs(entry, user)

    case do_update_note(existing, base_attrs, user, entry.path, entry.folder, entry.tags) do
      {:ok, {prev_hash, updated, merged_text, content_hash}} ->
        {:ok,
         %{
           id: updated.id,
           version: updated.version,
           prev_hash: prev_hash,
           updated_at: updated.updated_at,
           content: merged_text,
           content_hash: content_hash
         }}

      {:error, changeset} ->
        {:error, changeset}
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
           Engram.Notes.CrdtBridge.merge_plaintext(nil, content),
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
      |> Enum.filter(fn %{hash: hash, result: {:ok, info}} -> info.prev_hash != hash end)
      # clamp: false — Oban.insert_all ignores unique/replace, so the settle
      # ceiling is moot here; skip the per-note burst-start SELECT.
      |> Enum.map(fn %{result: {:ok, info}} ->
        EmbedNote.new_debounced(info.id, clamp: false)
      end)

    _ = if embed_jobs != [], do: Oban.insert_all(embed_jobs)

    # Same hash gate as the embed jobs: entries whose update short-circuited
    # (idempotent re-push, no version/seq persisted) must not appear in the
    # digest, or every batch re-sync fans a phantom change to all devices.
    changed_entries =
      Enum.filter(ok_entries, fn %{hash: hash, result: {:ok, info}} ->
        info.prev_hash != hash
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
            notes: digest
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
        Engram.Notes.CrdtDeliver.deliver_out(
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
            content_hash: entry.hash,
            # Canonical (sanitized) path — differs from `path` when the
            # sanitizer rewrote the input; clients rename local files to it.
            server_path: entry.path
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
    case get_note_by_id(user, vault, id) do
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
  Keyset-paginated variant of `list_changes/4` (sync protocol rev).

  Options:

    * `limit:` — page size, clamped to 1..#{@changes_page_max_limit}
      (default #{@changes_page_max_limit}).
    * `cursor:` — opaque cursor from a previous page's `next_cursor`.
      Encodes `(updated_at, id)`; rows are ordered by that pair so pages
      never lose or duplicate rows even when timestamps collide.
    * `fields: :meta` — skip the content column + its decrypt; entries carry
      `content_hash` instead (`content: nil`). Clients fetch bodies
      selectively for hashes they don't already hold.

  Returns `{:ok, %{changes: [...], has_more: bool, next_cursor: binary | nil}}`
  or `{:error, :invalid_cursor}`.
  """
  @spec list_changes_page(map(), map(), DateTime.t(), keyword()) ::
          {:ok, %{changes: [map()], has_more: boolean(), next_cursor: binary() | nil}}
          | {:error, :invalid_cursor}
  def list_changes_page(user, vault, since, opts \\ []) do
    limit =
      opts
      |> Keyword.get(:limit, @changes_page_max_limit)
      |> min(@changes_page_max_limit)
      |> max(1)

    fields = Keyword.get(opts, :fields, :all)

    with {:ok, cursor} <- decode_changes_cursor(Keyword.get(opts, :cursor)) do
      base =
        from(n in Note,
          where:
            n.user_id == ^user.id and n.vault_id == ^vault.id and n.updated_at >= ^since and
              n.kind == "note",
          order_by: [asc: n.updated_at, asc: n.id],
          limit: ^(limit + 1)
        )

      base =
        case cursor do
          nil ->
            base

          {ts, id} ->
            from(n in base,
              where: n.updated_at > ^ts or (n.updated_at == ^ts and n.id > ^id)
            )
        end

      query =
        case fields do
          :meta -> from(n in base, select: struct(n, @note_meta_fields))
          :all -> base
        end

      {:ok, notes} = Repo.with_tenant(user.id, fn -> Repo.all(query) end)

      {page, has_more} =
        if length(notes) > limit do
          {Enum.take(notes, limit), true}
        else
          {notes, false}
        end

      changes =
        page
        |> decrypt_or_raise!(user)
        |> Enum.map(&change_map/1)

      next_cursor =
        if has_more do
          last = List.last(page)
          encode_changes_cursor(last.updated_at, last.id)
        end

      {:ok, %{changes: changes, has_more: has_more, next_cursor: next_cursor}}
    end
  end

  @doc """
  Seq-cursor change feed: rows with `(seq, id) > (after_seq, after_id)`,
  ordered by `(seq, id)`, paginated.

  Unlike `list_changes_page/4` (the timestamp feed) this carries the FULL
  change set: ALL kinds (notes + folder markers) and tombstones (no
  `deleted_at` filter, no `kind == "note"` filter) so deletes / renames /
  folder ops all flow through the unified `/sync/changes` pull. Per-vault
  `seq` is monotonic and unique, so `(seq, id)` is a stable keyset that never
  loses or duplicates rows across pages.

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

    base =
      from(n in Note,
        where: n.user_id == ^user.id and n.vault_id == ^vault.id and not is_nil(n.seq),
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

    {:ok, notes} = Repo.with_tenant(user.id, fn -> Repo.all(query) end)

    {page, has_more} =
      if length(notes) > limit do
        {Enum.take(notes, limit), true}
      else
        {notes, false}
      end

    changes =
      page
      |> decrypt_or_raise!(user)
      |> Enum.map(fn note -> note |> change_map() |> Map.put(:seq, note.seq) end)

    next =
      if has_more do
        last = List.last(page)
        {last.seq, last.id}
      end

    {:ok, %{changes: changes, has_more: has_more, next: next}}
  end

  defp change_map(note) do
    %{
      id: note.id,
      path: note.path,
      title: note.title,
      folder: note.folder,
      tags: note.tags,
      version: note.version,
      mtime: note.mtime,
      content: note.content,
      content_hash: note.content_hash,
      deleted: not is_nil(note.deleted_at),
      updated_at: note.updated_at
    }
  end

  defp encode_changes_cursor(updated_at, id),
    do: Base.url_encode64("#{DateTime.to_iso8601(updated_at)}|#{id}", padding: false)

  defp decode_changes_cursor(nil), do: {:ok, nil}

  defp decode_changes_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [ts_str, id_str] <- String.split(raw, "|", parts: 2),
         {:ok, ts, _} <- DateTime.from_iso8601(ts_str),
         {:ok, id} <- Ecto.UUID.cast(id_str) do
      {:ok, {ts, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_changes_cursor(_), do: {:error, :invalid_cursor}

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
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.tags_ciphertext) and n.tags_hmac != ^[],
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
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.folder_hmac) and n.folder_hmac != ^empty_hmac,
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
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and
                    is_nil(n.deleted_at) and n.kind == "folder",
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
            from(n in Note,
              where:
                n.user_id == ^user.id and n.vault_id == ^vault.id and
                  is_nil(n.deleted_at) and n.kind == "folder",
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
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and
                    is_nil(n.deleted_at) and n.kind == "note" and
                    not is_nil(n.folder_hmac) and n.folder_hmac != ^empty_hmac,
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
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.tags_ciphertext) and n.tags_hmac != ^[],
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
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.folder_hmac),
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
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    n.kind == "note" and
                    n.folder_hmac == ^target_hmac,
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
               from(n in Note,
                 where:
                   n.id == ^id and
                     n.user_id == ^user.id and
                     n.vault_id == ^vault.id and
                     n.kind == "folder" and
                     is_nil(n.deleted_at)
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
    new_folder = String.trim_trailing(new_folder, "/")
    old_prefix = old_folder <> "/"

    with {:ok, user} <- Crypto.ensure_user_dek(user) do
      cond do
        # No-op rename: same folder. Skip the target conflict check so the
        # call is idempotent rather than colliding with itself.
        old_folder == new_folder ->
          do_rename_folder(user, vault, old_folder, old_prefix, new_folder)

        folder_target_exists?(user, vault, new_folder) ->
          # Pre-check the unique (user, vault, path_hmac) constraint so
          # the caller gets {:error, :conflict} instead of a Postgrex
          # unique_violation crash deeper in the cascade. Matches by
          # folder_hmac (exact match on the immediate folder) — covers
          # the common case of renaming onto a populated folder or an
          # existing folder marker.
          {:error, :conflict}

        true ->
          do_rename_folder(user, vault, old_folder, old_prefix, new_folder)
      end
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
        Repo.exists?(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and
                is_nil(n.deleted_at) and n.folder_hmac == ^target_hmac
          )
        )
      end)

    exists?
  end

  # Fetch + decrypt every live row in the vault for a folder-cascade scan
  # (Phase B.3: plaintext `folder` is gone, so prefix filtering happens in
  # Elixir over decrypted rows). Markers hydrate their single folder
  # envelope; real notes go through the parallel batch decryptor instead
  # of one-at-a-time. `:meta` skips the content column entirely for flows
  # that never rewrite content (delete cascades).
  defp fetch_decrypted_live_rows(user, vault, fields) do
    base =
      from(n in Note,
        where: n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at)
      )

    query =
      case fields do
        :meta -> from(n in base, select: struct(n, @note_meta_fields))
        :all -> base
      end

    {:ok, rows} = Repo.with_tenant(user.id, fn -> Repo.all(query) end)
    {:ok, dek} = Crypto.get_dek(user)

    # Marker rows have nil path_ciphertext, so the standard decrypt path
    # short-circuits before unwrapping the folder envelope — they go
    # through the dedicated hydrate path instead.
    {markers, real} = Enum.split_with(rows, &(&1.kind == "folder"))
    Enum.map(markers, &hydrate_folder_marker(&1, dek)) ++ decrypt_or_raise!(real, user)
  end

  defp do_rename_folder(user, vault, old_folder, old_prefix, new_folder) do
    decrypted = fetch_decrypted_live_rows(user, vault, :all)

    notes =
      Enum.filter(decrypted, fn n ->
        n.folder == old_folder or String.starts_with?(n.folder || "", old_prefix)
      end)

    if notes == [] do
      {:ok, 0}
    else
      now = DateTime.utc_now()
      old_len = String.length(old_folder)

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

                {np, Helpers.extract_title(note.content || "", np)}
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

          Enum.each(updates, fn {note, _old_path, new_path, new_note_folder, new_title} ->
            case note.kind do
              "folder" ->
                {ct, nonce, hmac} =
                  folder_only_aad_bound(user, note.id, new_note_folder, note.dek_version)

                from(n in Note, where: n.id == ^note.id)
                |> Repo.update_all(
                  set: [
                    folder_ciphertext: ct,
                    folder_nonce: nonce,
                    folder_hmac: hmac,
                    updated_at: now,
                    seq: seq
                  ]
                )

              _ ->
                full_kw =
                  full_aad_bound_kw(
                    user,
                    note.id,
                    note.content || "",
                    new_title,
                    new_path,
                    new_note_folder,
                    note.tags || []
                  )

                from(n in Note, where: n.id == ^note.id)
                |> Repo.update_all(
                  set:
                    [
                      updated_at: now,
                      seq: seq
                    ] ++ full_kw
                )
            end
          end)

          # Insert soft-deleted tombstones for old paths so the HTTP changes
          # feed includes delete signals. Without these, polling clients
          # retain stale files at old paths after a folder rename. Tombstones
          # are full-row inserts so each must carry the encrypted
          # path/folder/tags fields too. Marker rows have no path to
          # tombstone — skip them. Built in-memory from `real_note_updates`,
          # stamped with the same `seq` as the renamed rows.
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

      # Side effects outside the transaction — broadcast + reindex.
      # T3.2 — pass old_path_hmac (base64) to the worker, never plaintext.
      # Marker rows have no path / no embedding, skip the broadcast+enqueue.
      Enum.each(real_note_updates, fn {note, old_note_path, new_path, _folder, _title} ->
        _ =
          Enqueue.enqueue(
            Engram.Workers.RepathNoteIndex.new_debounced(note.id,
              old_path_hmac: old_path_hmac_b64!(user, old_note_path)
            ),
            "repath_note_index"
          )

        :ok = broadcast_change(user.id, vault.id, "delete", old_note_path)
        :ok = broadcast_change(user.id, vault.id, "upsert", new_path)
      end)

      {:ok, length(notes)}
    end
  end

  @doc """
  Soft-deletes a folder and every descendant (sub-markers and real notes).
  Mirrors `rename_folder/4`'s cascade shape: decrypts all live rows,
  filters by exact-match-or-prefix on `folder`, then bulk-updates
  `deleted_at` in one `update_all`.

  Returns `{:ok, %{deleted: count}}` where count includes the folder
  marker (if present) plus every descendant note and sub-marker. A folder
  that doesn't exist (no marker AND no notes underneath) returns
  `{:ok, %{deleted: 0}}` — same idempotency contract as `rename_folder/4`,
  which returns `{:ok, 0}` for an empty target.

  Side effects per real note (skipped for markers, matching `rename_folder`):
  - Decrement usage meter.
  - Enqueue `DeleteNoteIndex` worker to clean up Qdrant points.
  - Broadcast `note_changed` with `event_type: "delete"`.

  PubSub disclosure: broadcasts are not transactional. A batch caller that
  composes this on top of `Repo.transaction` (see `batch_delete_folders/2`)
  will leak per-note delete events for cascades that get rolled back. Same
  caveat as `batch_delete_notes/3` — the systemic fix (after-commit hooks)
  is tracked as a follow-up.
  """
  @spec delete_folder(map(), map(), String.t()) ::
          {:ok, %{deleted: non_neg_integer()}} | {:error, term()}
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
    prefixes = Enum.map(folders, &(&1 <> "/"))
    decrypted = fetch_decrypted_live_rows(user, vault, :meta)

    matches =
      Enum.filter(decrypted, fn r ->
        f = r.folder || ""
        f in folders or Enum.any?(prefixes, &String.starts_with?(f, &1))
      end)

    if matches == [] do
      {:ok, %{deleted: 0}}
    else
      now = DateTime.utc_now()
      ids = Enum.map(matches, & &1.id)

      {real_notes, _markers} = Enum.split_with(matches, fn r -> r.kind == "note" end)

      Repo.with_tenant(user.id, fn ->
        seq = Engram.Vaults.next_seq!(vault.id)

        {updated, _} =
          from(n in Note,
            where: n.id in ^ids and is_nil(n.deleted_at)
          )
          |> Repo.update_all(set: [deleted_at: now, updated_at: now, seq: seq])

        # Decrement only real notes — markers don't count against the meter.
        # `updated` may include both kinds; recompute live-real-note count from
        # the matched set so the meter delta lines up with notes_count semantics.
        real_count = length(real_notes)
        if real_count > 0, do: :ok = UsageMeters.dec_notes_count(user.id, real_count)
        updated
      end)

      # Side effects outside the transaction context — Qdrant cleanup + broadcasts.
      # Markers carry no embedding and no path, so skip them.
      Enum.each(real_notes, fn note ->
        _ =
          Enqueue.enqueue(
            DeleteNoteIndex.new(%{
              note_id: note.id,
              user_id: user.id,
              vault_id: vault.id,
              path_hmac: Base.encode64(note.path_hmac)
            }),
            "delete_note_index"
          )

        :ok = broadcast_change(user.id, vault.id, "delete", note.path)
      end)

      {:ok, %{deleted: length(matches)}}
    end
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
  fires `note_changed` broadcasts per affected real note inside the transaction.
  Subscribers may receive delete events for cascades that get rolled back when
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
            {:ok, %{deleted: n}} = do_delete_folders(user, vault, folders)
            %{deleted: n, folders: folders}
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
  defp reduce_move_folders(user, vault, marker_ids, target_folder, dek) do
    marker_ids
    |> Enum.reduce_while(%{moved: 0, pairs: []}, fn id, acc ->
      case move_folder_into(user, vault, id, target_folder, dek) do
        {:ok, {old_folder, new_folder}} ->
          {:cont, %{acc | moved: acc.moved + 1, pairs: [{old_folder, new_folder} | acc.pairs]}}

        {:error, :not_found} ->
          {:halt, {:rollback, {:not_found, id}}}

        {:error, :conflict} ->
          {:halt, {:rollback, {:conflict, id}}}

        {:error, :cycle} ->
          {:halt, {:rollback, {:cycle, id}}}

        {:error, reason} ->
          {:halt, {:rollback, reason}}
      end
    end)
    |> case do
      {:rollback, reason} -> Repo.rollback(reason)
      %{pairs: pairs} = acc -> %{acc | pairs: Enum.reverse(pairs)}
    end
  end

  # Resolve source marker → compute new folder under target → delegate to
  # rename_folder/4 (which cascades through descendants). Mirrors
  # move_note_into_folder/4's contract: returns {:ok, _} or {:error, atom}.
  defp move_folder_into(user, vault, id, target_folder, dek) do
    case get_folder_marker_by_id(user, vault, id) do
      {:ok, marker} ->
        source_folder = hydrate_folder_marker(marker, dek).folder

        # Cycle guard: moving a folder into itself or any descendant would
        # produce a path that's a strict suffix of the source, which both
        # `do_rename_folder/5`'s prefix scan can't reason about and is
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

          case rename_folder(user, vault, source_folder, new_folder) do
            {:ok, _count} -> {:ok, {source_folder, new_folder}}
            {:error, :conflict} -> {:error, :conflict}
            {:error, reason} -> {:error, reason}
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
    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id,
            select: n.id,
            limit: 2
        )
      end)

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

  defp broadcast_change(user_id, vault_id, "upsert", path, %Note{} = note, opts \\ []) do
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
    payload =
      Helpers.scrub_broadcast_payload(%{
        "event_type" => "upsert",
        "id" => note.id,
        "path" => path,
        "vault_id" => vault_id,
        "content" => note.content || "",
        "content_hash" => note.content_hash,
        "title" => note.title || "",
        "folder" => note.folder || "",
        "tags" => note.tags || [],
        "mtime" => note.mtime,
        "updated_at" => note.updated_at,
        "version" => note.version
      })

    topic = "sync:#{user_id}:#{vault_id}"

    _ =
      case Keyword.get(opts, :broadcast_from) do
        pid when is_pid(pid) ->
          # `broadcast_from` excludes the pushing socket; it is never used from
          # the folder cascade (which has no socket to exclude), so it stays a
          # direct Endpoint call and is not subject to deferral.
          EngramWeb.Endpoint.broadcast_from(pid, topic, "note_changed", payload)

        nil ->
          Engram.Sync.Broadcast.emit(topic, "note_changed", payload)
      end

    # Deliver-out to CRDT clients (gap ③): push the merged plaintext to a live
    # room's observers and announce the doc so clients lacking it pull. Runs
    # post-commit, best-effort. CRDT-origin writes never reach here (the
    # checkpoint writes the DB directly), so this fires solely for
    # REST/MCP/web/cascade writes — no double-delivery.
    _ = Engram.Notes.CrdtDeliver.deliver_out(user_id, vault_id, path, note.id, note.content || "")

    :ok
  end

  @spec broadcast_change(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t()) :: :ok
  defp broadcast_change(user_id, vault_id, event_type, path) do
    _ =
      Engram.Sync.Broadcast.emit("sync:#{user_id}:#{vault_id}", "note_changed", %{
        "event_type" => event_type,
        "path" => path,
        "vault_id" => vault_id
      })

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

  @doc false
  # Public delegate so `CrdtCheckpoint` can reuse the single source of truth
  # for HMAC + envelope computation without duplicating the phase-B logic.
  # The `defp` counterpart cannot be called across module boundaries; this
  # thin wrapper exposes it without promoting it to an official public API.
  def inject_phase_b_fields_pub(attrs, user, note_id, path, folder, tags) do
    inject_phase_b_fields(attrs, user, note_id, path, folder, tags)
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
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Crypto.hmac_field(filter_key, folder)
    ]
  end
end
