defmodule Engram.Notes do
  @moduledoc """
  Notes context — CRUD for notes, folders, and tags.
  All operations are tenant-scoped via Repo.with_tenant/2.
  """

  require Logger

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Notes.{Note, Helpers, PathSanitizer}
  alias Engram.Workers.{DeleteNoteIndex, EmbedNote}

  @doc """
  Creates or updates a note. Sanitizes path, extracts metadata, computes content_hash.
  Returns {:ok, note} or {:error, changeset}.
  """
  @spec upsert_note(map(), map(), map()) :: {:ok, Note.t()} | {:error, Ecto.Changeset.t()}
  def upsert_note(user, vault, attrs) do
    path = attrs["path"] || attrs[:path]
    content = attrs["content"] || attrs[:content] || ""
    mtime = attrs["mtime"] || attrs[:mtime]
    client_version = attrs["version"] || attrs[:version]

    with {:ok, user} <- Engram.Crypto.ensure_user_dek(user),
         {:ok, path} <- validate_path(path),
         sanitized_path = PathSanitizer.sanitize(path),
         title = Helpers.extract_title(content, sanitized_path),
         folder = Helpers.extract_folder(sanitized_path),
         tags = Helpers.extract_tags(content),
         {:ok, hash} <- content_hash(user, content),
         now = DateTime.utc_now(),
         note_attrs = %{
           content: content,
           title: title,
           tags: tags,
           content_hash: hash,
           mtime: mtime,
           user_id: user.id,
           vault_id: vault.id,
           created_at: now,
           updated_at: now
         },
         {:ok, note_attrs} <- Engram.Crypto.encrypt_note_fields(note_attrs, user),
         note_attrs = inject_phase_b_fields(note_attrs, user, sanitized_path, folder, tags) do
      changeset = Note.changeset(%Note{}, note_attrs)
      {:ok, lookup_query} = note_by_path_query(user, vault, sanitized_path)

      result =
        Repo.with_tenant(user.id, fn ->
          case Repo.one(lookup_query) do
            nil ->
              case Repo.insert(changeset) do
                {:ok, note} -> {:ok, {nil, note}}
                {:error, changeset} -> {:error, changeset}
              end

            existing ->
              if client_version != nil and client_version != existing.version do
                {:conflict, existing}
              else
                existing
                |> Note.changeset(Map.put(note_attrs, :version, existing.version + 1))
                |> Repo.update()
                |> case do
                  {:ok, updated} -> {:ok, {existing.content_hash, updated}}
                  {:error, changeset} -> {:error, changeset}
                end
              end
          end
        end)

      case result do
        {:ok, {:ok, {prev_hash, note}}} ->
          if prev_hash != note.content_hash do
            Oban.insert(EmbedNote.new_debounced(note.id))
          end

          note = decrypt_or_raise!(note, user)
          broadcast_change(user.id, vault.id, "upsert", note.path, note)
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
    with {:ok, filter_key} <- Engram.Crypto.dek_filter_key(user) do
      hmac = Engram.Crypto.hmac_field(filter_key, path)

      {:ok,
       from(n in Note,
         where:
           n.user_id == ^user.id and n.vault_id == ^vault.id and n.path_hmac == ^hmac and
             is_nil(n.deleted_at)
       )}
    end
  end

  @doc """
  Renames a note to a new path. Sanitizes the new path, updates folder and title.
  Returns {:ok, updated_note} or {:error, :not_found}.
  """
  @spec rename_note(map(), map(), String.t(), String.t()) ::
          {:ok, Note.t()} | {:error, :not_found}
  def rename_note(user, vault, old_path, new_path) do
    new_path = PathSanitizer.sanitize(new_path)
    new_folder = Helpers.extract_folder(new_path)
    now = DateTime.utc_now()

    with {:ok, user} <- Engram.Crypto.ensure_user_dek(user) do
      do_rename_note(user, vault, old_path, new_path, new_folder, now)
    end
  end

  defp do_rename_note(user, vault, old_path, new_path, new_folder, now) do
    {:ok, lookup_query} = note_by_path_query(user, vault, old_path)

    result =
      Repo.with_tenant(user.id, fn ->
        case Repo.one(lookup_query) do
          nil ->
            :not_found

          note ->
            decrypted_note = decrypt_or_raise!(note, user)
            new_title = Helpers.extract_title(decrypted_note.content || "", new_path)

            # Rename re-keys path/folder but not tags — preserve existing
            # tags_hmac/tags_ciphertext on the row.
            phase_b_kw = phase_b_path_folder_for(user, new_path, new_folder)

            # Phase B.4: title is virtual — encrypt the new title and write
            # title_ciphertext + title_nonce instead of the plaintext column.
            {:ok, dek} = Engram.Crypto.get_dek(user)
            {title_ct, title_nonce} = Engram.Crypto.Envelope.encrypt(new_title, dek)

            title_kw = [
              title_ciphertext: title_ct,
              title_nonce: title_nonce
            ]

            {count, _} =
              from(n in Note, where: n.id == ^note.id)
              |> Repo.update_all(
                set:
                  [
                    embed_hash: nil,
                    updated_at: now
                  ] ++ title_kw ++ phase_b_kw
              )

            if count == 1 do
              # Splice the freshly-encrypted Phase B fields into the in-memory
              # struct + populate the virtual path/folder fields so callers
              # (broadcast, MCP, controllers) read the new plaintext without
              # re-decrypting through maybe_decrypt_note_fields.
              {:ok,
               note
               |> struct!(phase_b_kw)
               |> struct!(title_kw)
               |> struct!(
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
      end)

    case result do
      {:ok, {:ok, note}} ->
        # T3.2 — pass old_path_hmac (base64) to the worker, never plaintext.
        Oban.insert(EmbedNote.new_debounced(note.id, old_path_hmac: old_path_hmac_b64!(user, old_path)))
        broadcast_change(user.id, vault.id, "delete", old_path)
        decrypted = decrypt_or_raise!(note, user)
        broadcast_change(user.id, vault.id, "upsert", note.path, decrypted)
        {:ok, decrypted}

      {:ok, :not_found} ->
        {:error, :not_found}

      _ ->
        {:error, :not_found}
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

    if note do
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(set: [deleted_at: now, updated_at: now])
      end)

      # T3.2 — pass path_hmac (base64), never plaintext path. The note row
      # already carries `path_hmac` raw bytes; base64-encode for JSON safety.
      Oban.insert(
        DeleteNoteIndex.new(%{
          note_id: note.id,
          user_id: note.user_id,
          vault_id: note.vault_id,
          path_hmac: Base.encode64(note.path_hmac)
        })
      )
    end

    broadcast_change(user.id, vault.id, "delete", path)
    :ok
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
            where: n.user_id == ^user.id and n.vault_id == ^vault.id and n.updated_at >= ^since,
            order_by: [asc: n.updated_at]
          )
        )
      end)

    changes =
      Enum.map(notes, fn note ->
        note = decrypt_or_raise!(note, user)

        %{
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
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Engram.Crypto.get_dek(user)

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.tags_ciphertext) and n.tags_hmac != ^[],
                select: {n.tags_ciphertext, n.tags_nonce}
              )
            )
          end)

        tags =
          rows
          |> Enum.flat_map(fn {ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek) |> :erlang.binary_to_term([:safe])
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
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        {:ok, dek} = Engram.Crypto.get_dek(user)
        empty_hmac = Engram.Crypto.hmac_field(filter_key, "")

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.folder_hmac) and n.folder_hmac != ^empty_hmac,
                distinct: n.folder_hmac,
                select: {n.folder_ciphertext, n.folder_nonce}
              )
            )
          end)

        folders =
          rows
          |> Enum.map(fn {ct, nonce} -> decrypt_envelope!(ct, nonce, dek) end)
          |> Enum.sort()

        {:ok, folders}

      # No DEK = user has no encrypted data possible = no folders.
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
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Engram.Crypto.get_dek(user)

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.tags_ciphertext) and n.tags_hmac != ^[],
                select: {n.tags_ciphertext, n.tags_nonce}
              )
            )
          end)

        counts =
          rows
          |> Enum.flat_map(fn {ct, nonce} ->
            decrypt_envelope!(ct, nonce, dek) |> :erlang.binary_to_term([:safe])
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
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, _filter_key} ->
        {:ok, dek} = Engram.Crypto.get_dek(user)

        {:ok, rows} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                    not is_nil(n.folder_hmac),
                distinct: n.folder_hmac,
                select: %{
                  ct: n.folder_ciphertext,
                  nonce: n.folder_nonce,
                  count: fragment("COUNT(*) OVER (PARTITION BY ?)", n.folder_hmac)
                }
              )
            )
          end)

        folders =
          rows
          |> Enum.map(fn %{ct: ct, nonce: nonce, count: count} ->
            %{folder: decrypt_envelope!(ct, nonce, dek), count: count}
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
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        target_hmac = Engram.Crypto.hmac_field(filter_key, folder)

        {:ok, notes} =
          Repo.with_tenant(user.id, fn ->
            Repo.all(
              from(n in Note,
                where:
                  n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
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
  Renames a folder and all notes within it (including subfolders).
  Rewrites path, folder, and title for each affected note.
  Returns {:ok, count} with the number of notes affected.
  """
  @spec rename_folder(map(), map(), String.t(), String.t()) :: {:ok, integer()}
  def rename_folder(user, vault, old_folder, new_folder) do
    new_folder = String.trim_trailing(new_folder, "/")
    old_prefix = old_folder <> "/"

    with {:ok, user} <- Engram.Crypto.ensure_user_dek(user) do
      do_rename_folder(user, vault, old_folder, old_prefix, new_folder)
    end
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

    decrypted = Enum.map(all_notes, &decrypt_or_raise!(&1, user))

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
      # then apply as a single update per note (avoids N+1 per-row queries)
      updates =
        Enum.map(notes, fn note ->
          new_note_folder =
            if note.folder == old_folder do
              new_folder
            else
              new_folder <> String.slice(note.folder, old_len..-1//1)
            end

          new_path = new_note_folder <> String.slice(note.path, String.length(note.folder)..-1//1)
          new_title = Helpers.extract_title(note.content || "", new_path)

          {note.id, note.path, new_path, new_note_folder, new_title}
        end)

      {:ok, dek} = Engram.Crypto.get_dek(user)

      Repo.with_tenant(user.id, fn ->
        Enum.each(updates, fn {id, _old_path, new_path, new_note_folder, new_title} ->
          phase_b_kw = phase_b_path_folder_for(user, new_path, new_note_folder)
          {title_ct, title_nonce} = Engram.Crypto.Envelope.encrypt(new_title, dek)

          from(n in Note, where: n.id == ^id)
          |> Repo.update_all(
            set:
              [
                title_ciphertext: title_ct,
                title_nonce: title_nonce,
                embed_hash: nil,
                updated_at: now
              ] ++ phase_b_kw
          )
        end)
      end)

      # Insert soft-deleted tombstones for old paths so the HTTP changes feed
      # includes delete signals. Without these, polling clients retain stale
      # files at old paths after a folder rename. Tombstones are full-row
      # inserts so each must carry the encrypted path/folder/tags fields too.
      mtime_float = DateTime.to_unix(now) + 0.0

      {empty_tags_ct, empty_tags_nonce} =
        Engram.Crypto.Envelope.encrypt(:erlang.term_to_binary([]), dek)

      {empty_title_ct, empty_title_nonce} = Engram.Crypto.Envelope.encrypt("", dek)
      {empty_content_ct, empty_content_nonce} = Engram.Crypto.Envelope.encrypt("", dek)

      tombstones =
        Enum.map(updates, fn {_id, old_path, _new_path, _new_folder, _title} ->
          old_path_folder = Helpers.extract_folder(old_path)
          phase_b_kw = phase_b_path_folder_for(user, old_path, old_path_folder)

          base = %{
            content_hash: "",
            mtime: mtime_float,
            title_ciphertext: empty_title_ct,
            title_nonce: empty_title_nonce,
            content_ciphertext: empty_content_ct,
            content_nonce: empty_content_nonce,
            tags_ciphertext: empty_tags_ct,
            tags_nonce: empty_tags_nonce,
            tags_hmac: [],
            user_id: user.id,
            vault_id: vault.id,
            created_at: now,
            updated_at: now,
            deleted_at: now
          }

          Map.merge(base, Map.new(phase_b_kw))
        end)

      Repo.with_tenant(user.id, fn ->
        Repo.insert_all(Note, tombstones, on_conflict: :nothing)
      end)

      # Side effects outside the transaction — broadcast + reindex.
      # T3.2 — pass old_path_hmac (base64) to the worker, never plaintext.
      Enum.each(updates, fn {id, old_note_path, new_path, _folder, _title} ->
        Oban.insert(
          Engram.Workers.EmbedNote.new_debounced(id,
            old_path_hmac: old_path_hmac_b64!(user, old_note_path)
          )
        )

        broadcast_change(user.id, vault.id, "delete", old_note_path)
        broadcast_change(user.id, vault.id, "upsert", new_path)
      end)

      {:ok, length(notes)}
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
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    filter_key |> Engram.Crypto.hmac_field(path) |> Base.encode64()
  end

  # Phase B.3: decryption MUST raise on failure. Returning the un-decrypted
  # struct (with virtual path/folder/tags = nil) silently serializes
  # `{"path": null, "tags": []}` over a 200 OK and ships malformed sync events
  # to every connected device. Decrypt failure on persisted ciphertext means
  # real data corruption — surface it as a 5xx with a Sentry hit so operators
  # can intervene, never paper over it.
  defp decrypt_or_raise!(nil, _user), do: nil

  defp decrypt_or_raise!(%Note{} = note, user) do
    case Engram.Crypto.maybe_decrypt_note_fields(note, user) do
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

  # Decrypts an envelope (ciphertext + nonce) with the user's DEK.
  # Raises if decryption fails — used in Phase B aggregations where a failure
  # means data corruption, not a recoverable condition.
  defp decrypt_envelope!(ct, nonce, dek) do
    case Engram.Crypto.Envelope.decrypt(ct, nonce, dek) do
      {:ok, plaintext} -> plaintext
      :error -> raise "Phase B envelope decryption failed"
    end
  end

  defp validate_path(nil),
    do:
      {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}

  defp validate_path(""),
    do:
      {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}

  defp validate_path(path), do: {:ok, path}

  defp content_hash(user, content) do
    with {:ok, key} <- Engram.Crypto.dek_content_hash_key(user) do
      {:ok, Engram.Crypto.hmac_content_hash(key, content)}
    end
  end

  defp broadcast_change(user_id, vault_id, "upsert", path, %Note{} = note) do
    EngramWeb.Endpoint.broadcast("sync:#{user_id}:#{vault_id}", "note_changed", %{
      "event_type" => "upsert",
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
  end

  defp broadcast_change(user_id, vault_id, event_type, path) do
    EngramWeb.Endpoint.broadcast("sync:#{user_id}:#{vault_id}", "note_changed", %{
      "event_type" => event_type,
      "path" => path,
      "vault_id" => vault_id
    })
  end

  # Phase B.1 dual-write — computes HMAC + envelope-encrypts each filterable field.
  # Returns the original attrs map merged with phase_b_* fields.
  # Callers MUST call ensure_user_dek/1 before invoking this helper.
  # If get_dek still fails after ensure, that is a real bug — raises rather
  # than silently skipping to enforce the "Phase B is mandatory" contract.
  defp inject_phase_b_fields(attrs, user, path, folder, tags) do
    Map.merge(attrs, Map.new(phase_b_keyword_for(user, path, folder, tags)))
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
  defp phase_b_keyword_for(user, path, folder, tags) do
    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    tags = tags || []
    {tags_ct, tags_n} = Engram.Crypto.Envelope.encrypt(:erlang.term_to_binary(tags), dek)

    phase_b_path_folder_for(user, path, folder) ++
      [
        tags_ciphertext: tags_ct,
        tags_nonce: tags_n,
        tags_hmac: Enum.map(tags, &Engram.Crypto.hmac_field(filter_key, &1))
      ]
  end

  # Same as phase_b_keyword_for/4 but only re-keys path + folder. Used by
  # rename paths that don't change tags — preserves the existing tags_hmac /
  # tags_ciphertext on the row.
  defp phase_b_path_folder_for(user, path, folder) do
    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    {path_ct, path_n} = Engram.Crypto.Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Engram.Crypto.Envelope.encrypt(folder, dek)

    [
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Engram.Crypto.hmac_field(filter_key, path),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Engram.Crypto.hmac_field(filter_key, folder)
    ]
  end
end
