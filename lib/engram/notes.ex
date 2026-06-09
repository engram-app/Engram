defmodule Engram.Notes do
  @moduledoc """
  Notes context — CRUD for notes, folders, and tags.
  All operations are tenant-scoped via Repo.with_tenant/2.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{Enqueue, Helpers, Note, PathSanitizer}
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Workers.{DeleteNoteIndex, EmbedNote}

  require Logger

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
    marker_id = Crypto.next_row_id(:notes)
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

    %Note{id: marker_id}
    |> Note.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, marker} ->
        {:ok, hydrate_folder_marker(marker, dek)}

      {:error, %Ecto.Changeset{errors: errors}} = err ->
        # Race: concurrent insert of the same marker collapses to the
        # winner. Re-fetch and return rather than surface a constraint
        # error — keeps the API idempotent under load.
        if has_unique_conflict?(errors) do
          case find_folder_marker(user, vault, folder_hmac) do
            {:ok, existing} -> {:ok, hydrate_folder_marker(existing, dek)}
            :not_found -> err
          end
        else
          err
        end
    end
  end

  defp has_unique_conflict?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
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
  """
  @spec upsert_note(map(), map(), map()) ::
          {:ok, Note.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :version_conflict, Note.t()}
          | {:error, {:notes_cap_reached, non_neg_integer(), non_neg_integer()}}
          | {:error, atom()}
  def upsert_note(user, vault, attrs) do
    path = attrs["path"] || attrs[:path]
    content = attrs["content"] || attrs[:content] || ""
    mtime = attrs["mtime"] || attrs[:mtime]
    client_version = attrs["version"] || attrs[:version]

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
              insert_new_note(base_attrs, user, sanitized_path, folder, tags)

            existing ->
              update_existing_note(
                existing,
                base_attrs,
                user,
                sanitized_path,
                folder,
                tags,
                client_version
              )
          end
        end)

      case result do
        {:ok, {:ok, {prev_hash, note}}} ->
          _ =
            if prev_hash != note.content_hash do
              Enqueue.enqueue(EmbedNote.new_debounced(note.id), "embed_note")
            end

          note = decrypt_or_raise!(note, user)
          :ok = broadcast_change(user.id, vault.id, "upsert", note.path, note)

          if is_nil(prev_hash) do
            # FTUX vault page listens for this — fires when an empty vault
            # gets its first note (typical case: Obsidian plugin completes
            # its first sync push).
            maybe_broadcast_vault_populated(user, vault)

            # Funnel telemetry — emit once per real creation so the funnel
            # doesn't double-count idempotent re-pushes of unchanged notes.
            :ok =
              Engram.Observability.PostHog.capture(
                Engram.Observability.PostHog.distinct_id_for(user),
                "note_created",
                %{vault_id: vault.id}
              )
          end

          {:ok, note}

        {:ok, {:conflict, existing}} ->
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

  defp insert_new_note(base_attrs, user, sanitized_path, folder, tags) do
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
        # ("notes:<column>:<id>") can be computed before INSERT.
        note_id = Crypto.next_row_id(:notes)

        with {:ok, encrypted} <- Crypto.encrypt_note_fields(base_attrs, user, note_id) do
          phase_b = inject_phase_b_fields(encrypted, user, note_id, sanitized_path, folder, tags)
          changeset = Note.changeset(%Note{id: note_id}, phase_b)

          case Repo.insert(changeset) do
            {:ok, note} ->
              :ok = UsageMeters.inc_notes_count(user.id, 1)
              {:ok, {nil, note}}

            {:error, changeset} ->
              {:error, changeset}
          end
        end
    end
  end

  defp update_existing_note(
         existing,
         base_attrs,
         user,
         sanitized_path,
         folder,
         tags,
         client_version
       ) do
    if client_version != nil and client_version != existing.version do
      {:conflict, existing}
    else
      do_update_note(existing, base_attrs, user, sanitized_path, folder, tags)
    end
  end

  defp do_update_note(existing, base_attrs, user, sanitized_path, folder, tags) do
    with {:ok, encrypted} <- Crypto.encrypt_note_fields(base_attrs, user, existing.id) do
      phase_b = inject_phase_b_fields(encrypted, user, existing.id, sanitized_path, folder, tags)

      existing
      |> Note.changeset(Map.put(phase_b, :version, existing.version + 1))
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, {existing.content_hash, updated}}
        {:error, changeset} -> {:error, changeset}
      end
    end
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
  Gets a note by its primary key id, scoped to the given user + vault.

  Returns `{:ok, note}` when found and owned by the caller, `{:error, :not_found}`
  otherwise (including cross-tenant lookups and soft-deleted rows). Mirrors the
  decrypt-on-read shape of `get_note/3` but keys by `notes.id` instead of
  `path_hmac` — used by URL-by-id endpoints where the client holds a stable id.

  RLS scopes the SELECT to the caller's tenant; the explicit
  `user_id`/`vault_id` predicate is belt-and-suspenders.
  """
  @spec get_note_by_id(map(), map(), integer()) :: {:ok, Note.t()} | {:error, :not_found}
  def get_note_by_id(user, vault, id) when is_integer(id) do
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
        # T3.2 — pass old_path_hmac (base64) to the worker, never plaintext.
        _ =
          Enqueue.enqueue(
            EmbedNote.new_debounced(note.id, old_path_hmac: old_path_hmac_b64!(user, old_path)),
            "embed_note"
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

    {count, _} =
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        set:
          [
            embed_hash: nil,
            updated_at: now
          ] ++ full_kw
      )

    if count == 1 do
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
            {updated, _} =
              from(n in Note, where: n.id == ^note.id and is_nil(n.deleted_at))
              |> Repo.update_all(set: [deleted_at: now, updated_at: now])

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
  @spec delete_note_by_id(map(), map(), integer()) :: :ok | {:error, :not_found}
  def delete_note_by_id(user, vault, id) when is_integer(id) do
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
  @spec batch_move_notes(map(), map(), [integer()], integer()) ::
          {:ok, %{moved: non_neg_integer()}}
          | {:error, {:not_found | :conflict, integer()} | term()}
  def batch_move_notes(_user, _vault, [], _target_folder_id), do: {:ok, %{moved: 0}}

  def batch_move_notes(user, vault, ids, target_folder_id)
      when is_list(ids) and is_integer(target_folder_id) do
    Repo.transaction(fn ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, marker} <- get_folder_marker_by_id(user, vault, target_folder_id),
           {:ok, dek} <- Crypto.get_dek(user) do
        target_folder = hydrate_folder_marker(marker, dek).folder

        ids
        |> Enum.reduce_while(%{moved: 0}, fn id, acc ->
          case move_note_into_folder(user, vault, id, target_folder) do
            {:ok, _} -> {:cont, Map.update!(acc, :moved, &(&1 + 1))}
            # move_note_into_folder wraps the conflict error as
            # {:error, {:conflict, id}}; the bare :not_found from the inner
            # get_note_by_id propagates through `with`.
            {:error, {kind, id_err}} -> {:halt, {:rollback, {kind, id_err}}}
            {:error, :not_found} -> {:halt, {:rollback, {:not_found, id}}}
          end
        end)
        |> case do
          {:rollback, reason} -> Repo.rollback(reason)
          acc -> acc
        end
      else
        {:error, :not_found} -> Repo.rollback({:not_found, target_folder_id})
        {:error, reason} -> Repo.rollback(reason)
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

  @doc """
  Returns notes changed (upserted or deleted) since the given datetime.
  Deleted notes are included with deleted: true.
  """
  @spec list_changes(map(), map(), DateTime.t()) :: {:ok, [map()]}
  def list_changes(user, vault, since) do
    {:ok, notes} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and n.updated_at >= ^since and
                n.kind == "note",
            order_by: [asc: n.updated_at]
          )
        )
      end)

    changes =
      Enum.map(notes, fn note ->
        note = decrypt_or_raise!(note, user)

        %{
          id: note.id,
          path: note.path,
          title: note.title,
          folder: note.folder,
          tags: note.tags,
          version: note.version,
          mtime: note.mtime,
          content: note.content,
          deleted: not is_nil(note.deleted_at),
          updated_at: note.updated_at
        }
      end)

    {:ok, changes}
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
  user/vault, with `.folder` decrypted. Used by Materialization to compute
  the existing-marker set and by callers that need full marker structs
  (vs. `list_explicit_folders/2` which only returns sorted names).
  """
  @spec list_folder_markers(map(), map()) :: [Note.t()]
  def list_folder_markers(user, vault) do
    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      {:ok, markers} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(
            from(n in Note,
              where:
                n.user_id == ^user.id and n.vault_id == ^vault.id and
                  is_nil(n.deleted_at) and n.kind == "folder"
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

        {:ok, notes} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    n.kind == "note" and
                    n.folder_hmac == ^target_hmac,
                order_by: [asc: n.id]
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
  @spec list_folder_notes_by_id(map(), map(), integer()) ::
          {:ok, [Note.t()]} | {:error, :not_found}
  def list_folder_notes_by_id(user, vault, marker_id) when is_integer(marker_id) do
    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, marker} <- get_folder_marker_by_id(user, vault, marker_id),
         {:ok, dek} <- Crypto.get_dek(user) do
      hydrated = hydrate_folder_marker(marker, dek)
      list_notes_in_folder(user, vault, hydrated.folder)
    end
  end

  @spec get_folder_marker_by_id(map(), map(), integer()) ::
          {:ok, Note.t()} | {:error, :not_found}
  defp get_folder_marker_by_id(user, vault, id) when is_integer(id) do
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

  defp do_rename_folder(user, vault, old_folder, old_prefix, new_folder) do
    # Phase B.3: plaintext `folder` column is gone — can't `WHERE folder LIKE
    # 'prefix/%'` in SQL. Load all non-deleted notes, decrypt path+folder,
    # then filter by prefix in Elixir. Single decrypt per row, then bulk
    # updates use the already-decrypted plaintext.
    {:ok, all_notes} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at),
            select: n
          )
        )
      end)

    # Marker rows have nil path_ciphertext, so the standard decrypt path
    # short-circuits before unwrapping the folder envelope (gated on
    # path_ciphertext != nil). Branch on kind so markers go through the
    # dedicated hydrate path Task 4 introduced — they still carry a
    # folder, so the prefix-match filter below catches them alongside
    # real notes.
    {:ok, dek} = Crypto.get_dek(user)

    decrypted =
      Enum.map(all_notes, fn note ->
        case note.kind do
          "folder" -> hydrate_folder_marker(note, dek)
          _ -> decrypt_or_raise!(note, user)
        end
      end)

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

      Repo.with_tenant(user.id, fn ->
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
                  updated_at: now
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
                    embed_hash: nil,
                    updated_at: now
                  ] ++ full_kw
              )
          end
        end)
      end)

      # Insert soft-deleted tombstones for old paths so the HTTP changes feed
      # includes delete signals. Without these, polling clients retain stale
      # files at old paths after a folder rename. Tombstones are full-row
      # inserts so each must carry the encrypted path/folder/tags fields too.
      # Marker rows have no path to tombstone — skip them.
      mtime_float = DateTime.to_unix(now) + 0.0

      real_note_updates =
        Enum.reject(updates, fn {note, _, _, _, _} -> note.kind == "folder" end)

      tombstones =
        Enum.map(real_note_updates, fn {_note, old_path, _new_path, _new_folder, _title} ->
          # T3.6 — pre-allocate the tombstone id so the AAD bind string can
          # be constructed before insert. Tombstones are full-row inserts
          # written with empty content/title/tags but the row-id-bound AAD
          # still applies — keeps tombstones decryptable and indistinguishable
          # from any other AAD-bound row at read time.
          tomb_id = Crypto.next_row_id(:notes)
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
            deleted_at: now
          }

          Map.merge(base, Map.new(full_kw))
        end)

      Repo.with_tenant(user.id, fn ->
        Repo.insert_all(Note, tombstones, on_conflict: :nothing)
      end)

      # Side effects outside the transaction — broadcast + reindex.
      # T3.2 — pass old_path_hmac (base64) to the worker, never plaintext.
      # Marker rows have no path / no embedding, skip the broadcast+enqueue.
      Enum.each(real_note_updates, fn {note, old_note_path, new_path, _folder, _title} ->
        _ =
          Enqueue.enqueue(
            Engram.Workers.EmbedNote.new_debounced(note.id,
              old_path_hmac: old_path_hmac_b64!(user, old_note_path)
            ),
            "embed_note"
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

  defp do_delete_folder(user, vault, folder) do
    prefix = folder <> "/"

    # Phase B.3 mirror of do_rename_folder/5: plaintext `folder` is gone,
    # so we cannot prefix-filter in SQL. Load all live rows, decrypt the
    # folder envelope, then filter in Elixir.
    {:ok, all_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at),
            select: n
          )
        )
      end)

    {:ok, dek} = Crypto.get_dek(user)

    decrypted =
      Enum.map(all_rows, fn row ->
        case row.kind do
          "folder" -> hydrate_folder_marker(row, dek)
          _ -> decrypt_or_raise!(row, user)
        end
      end)

    matches =
      Enum.filter(decrypted, fn r ->
        r.folder == folder or String.starts_with?(r.folder || "", prefix)
      end)

    if matches == [] do
      {:ok, %{deleted: 0}}
    else
      now = DateTime.utc_now()
      ids = Enum.map(matches, & &1.id)

      {real_notes, _markers} = Enum.split_with(matches, fn r -> r.kind == "note" end)

      Repo.with_tenant(user.id, fn ->
        {updated, _} =
          from(n in Note,
            where: n.id in ^ids and is_nil(n.deleted_at)
          )
          |> Repo.update_all(set: [deleted_at: now, updated_at: now])

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
          {:ok, %{deleted: non_neg_integer()}}
          | {:error, {:not_found, integer()} | term()}
  def batch_delete_folders(_user, _vault, []), do: {:ok, %{deleted: 0}}

  def batch_delete_folders(user, vault, marker_ids) when is_list(marker_ids) do
    Repo.transaction(fn ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, dek} <- Crypto.get_dek(user) do
        marker_ids
        |> Enum.reduce_while(%{deleted: 0}, fn id, acc ->
          case get_folder_marker_by_id(user, vault, id) do
            {:ok, marker} ->
              folder = hydrate_folder_marker(marker, dek).folder
              # do_delete_folder/3 returns {:ok, %{deleted: n}} only — Crypto.ensure_user_dek
              # already ran above so the error path is unreachable here.
              {:ok, %{deleted: n}} = do_delete_folder(user, vault, folder)
              {:cont, Map.update!(acc, :deleted, &(&1 + n))}

            {:error, :not_found} ->
              {:halt, {:rollback, {:not_found, id}}}
          end
        end)
        |> case do
          {:rollback, reason} -> Repo.rollback(reason)
          acc -> acc
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
  @spec batch_move_folders(map(), map(), [integer()], integer()) ::
          {:ok, %{moved: non_neg_integer()}}
          | {:error, {:not_found | :conflict | :cycle, integer()} | term()}
  def batch_move_folders(_user, _vault, [], _target_folder_id), do: {:ok, %{moved: 0}}

  def batch_move_folders(user, vault, marker_ids, target_folder_id)
      when is_list(marker_ids) and is_integer(target_folder_id) do
    Repo.transaction(fn ->
      with {:ok, user} <- Crypto.ensure_user_dek(user),
           {:ok, target_marker} <- get_folder_marker_by_id(user, vault, target_folder_id),
           {:ok, dek} <- Crypto.get_dek(user) do
        target_folder = hydrate_folder_marker(target_marker, dek).folder

        marker_ids
        |> Enum.reduce_while(%{moved: 0}, fn id, acc ->
          case move_folder_into(user, vault, id, target_folder, dek) do
            {:ok, _} -> {:cont, Map.update!(acc, :moved, &(&1 + 1))}
            {:error, :not_found} -> {:halt, {:rollback, {:not_found, id}}}
            {:error, :conflict} -> {:halt, {:rollback, {:conflict, id}}}
            {:error, :cycle} -> {:halt, {:rollback, {:cycle, id}}}
            {:error, reason} -> {:halt, {:rollback, reason}}
          end
        end)
        |> case do
          {:rollback, reason} -> Repo.rollback(reason)
          acc -> acc
        end
      else
        {:error, :not_found} -> Repo.rollback({:not_found, target_folder_id})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
            {:ok, _count} -> {:ok, new_folder}
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
        Logger.error(
          "decrypt_failed user_id=#{user.id} note_id=#{note.id} reason=#{inspect(reason)}"
        )

        raise "Phase B note decryption failed: user_id=#{user.id} note_id=#{note.id} reason=#{inspect(reason)}"
    end
  end

  defp decrypt_or_raise!(notes, user) when is_list(notes) do
    Enum.map(notes, &decrypt_or_raise!(&1, user))
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

  @spec broadcast_change(integer(), integer(), String.t(), String.t(), Note.t()) :: :ok
  # Emits `vault_populated` only when this insert took the vault from 0
  # to 1 notes. Subsequent inserts skip the broadcast; the FTUX listener
  # is one-shot anyway, but avoiding extra channel traffic keeps the
  # invariant readable from the server side too.
  defp maybe_broadcast_vault_populated(user, vault) do
    {:ok, count} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id,
            select: count(n.id)
        )
      end)

    _ =
      if count == 1 do
        EngramWeb.Endpoint.broadcast(
          "user:#{user.id}",
          "vault_populated",
          %{vault_id: vault.id}
        )
      end

    :ok
  end

  defp broadcast_change(user_id, vault_id, "upsert", path, %Note{} = note) do
    _ =
      EngramWeb.Endpoint.broadcast("sync:#{user_id}:#{vault_id}", "note_changed", %{
        "event_type" => "upsert",
        "id" => note.id,
        "path" => path,
        "vault_id" => vault_id,
        "content" => note.content || "",
        "title" => note.title || "",
        "folder" => note.folder || "",
        "tags" => note.tags || [],
        "mtime" => note.mtime,
        "updated_at" => note.updated_at,
        "version" => note.version
      })

    :ok
  end

  @spec broadcast_change(integer(), integer(), String.t(), String.t()) :: :ok
  defp broadcast_change(user_id, vault_id, event_type, path) do
    _ =
      EngramWeb.Endpoint.broadcast("sync:#{user_id}:#{vault_id}", "note_changed", %{
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
