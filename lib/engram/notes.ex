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
         hash = content_hash(content),
         now = DateTime.utc_now(),
         note_attrs = %{
           path: sanitized_path,
           content: content,
           title: title,
           folder: folder,
           tags: tags,
           content_hash: hash,
           mtime: mtime,
           user_id: user.id,
           vault_id: vault.id,
           created_at: now,
           updated_at: now
         },
         {:ok, note_attrs} <- Engram.Crypto.maybe_encrypt_note_fields(note_attrs, user, vault),
         note_attrs = inject_phase_b_fields(note_attrs, user, sanitized_path, folder, tags) do
      changeset = Note.changeset(%Note{}, note_attrs)

      result =
        Repo.with_tenant(user.id, fn ->
          case Repo.get_by(Note, user_id: user.id, vault_id: vault.id, path: sanitized_path) do
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

          note = decrypt_for_broadcast(note, user)
          broadcast_change(user.id, vault.id, "upsert", note.path, note)
          {:ok, note}

        {:ok, {:conflict, existing}} ->
          {:error, :version_conflict, existing}

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
    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and n.path == ^path and
                is_nil(n.deleted_at)
          )
        )
      end)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, note} -> {:ok, decrypt_if_needed(note, user)}
      _ -> {:error, :not_found}
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

    result =
      Repo.with_tenant(user.id, fn ->
        # Fetch current note for content (to derive title from new path)
        case Repo.one(
               from(n in Note,
                 where:
                   n.user_id == ^user.id and n.vault_id == ^vault.id and n.path == ^old_path and
                     is_nil(n.deleted_at)
               )
             ) do
          nil ->
            :not_found

          note ->
            decrypted_note = decrypt_if_needed(note, user)
            new_title = Helpers.extract_title(decrypted_note.content || "", new_path)

            {count, _} =
              from(n in Note, where: n.id == ^note.id)
              |> Repo.update_all(
                set: [
                  path: new_path,
                  folder: new_folder,
                  title: new_title,
                  embed_hash: nil,
                  updated_at: now
                ]
              )

            if count == 1 do
              {:ok,
               %{
                 note
                 | path: new_path,
                   folder: new_folder,
                   title: new_title,
                   embed_hash: nil,
                   updated_at: now
               }}
            else
              :not_found
            end
        end
      end)

    case result do
      {:ok, {:ok, note}} ->
        Oban.insert(EmbedNote.new_debounced(note.id, old_path: old_path))
        broadcast_change(user.id, vault.id, "delete", old_path)
        decrypted = decrypt_for_broadcast(note, user)
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

    {:ok, note} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and n.path == ^path and
                is_nil(n.deleted_at)
          )
        )
      end)

    if note do
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(set: [deleted_at: now, updated_at: now])
      end)

      Oban.insert(
        DeleteNoteIndex.new(%{
          note_id: note.id,
          user_id: note.user_id,
          vault_id: note.vault_id,
          path: note.path
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
        note = decrypt_if_needed(note, user)

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
  """
  @spec list_tags(map(), map()) :: {:ok, [String.t()]}
  def list_tags(user, vault) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                n.tags != ^[],
            select: n.tags
          )
        )
      end)

    tags =
      rows
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, tags}
  end

  @doc """
  Returns unique non-empty folder paths for a user's notes.
  """
  @spec list_folders(map(), map()) :: {:ok, [String.t()]}
  def list_folders(user, vault) do
    {:ok, folders} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                n.folder != "" and
                not is_nil(n.folder),
            select: n.folder,
            distinct: true,
            order_by: n.folder
          )
        )
      end)

    {:ok, folders}
  end

  @doc """
  Returns tags with counts across all non-deleted notes for a user.
  Uses Postgres unnest() to explode the tags array and group by tag.
  """
  @spec list_tags_with_counts(map(), map()) :: {:ok, [%{name: String.t(), count: integer()}]}
  def list_tags_with_counts(user, vault) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                n.tags != ^[],
            select: %{
              name: fragment("unnest(?)", n.tags),
              count: fragment("1")
            }
          )
        )
      end)

    # Group and count in Elixir since unnest in select doesn't allow group_by directly
    counts =
      rows
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {name, items} -> %{name: name, count: length(items)} end)
      |> Enum.sort_by(& &1.name)

    {:ok, counts}
  end

  @doc """
  Returns folders with note counts for a user. Includes root folder (empty string).
  """
  @spec list_folders_with_counts(map(), map()) ::
          {:ok, [%{folder: String.t(), count: integer()}]}
  def list_folders_with_counts(user, vault) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at),
            group_by: n.folder,
            select: %{folder: n.folder, count: count(n.id)},
            order_by: n.folder
          )
        )
      end)

    # Normalize nil folder to ""
    rows = Enum.map(rows, fn r -> %{r | folder: r.folder || ""} end)

    {:ok, rows}
  end

  @doc """
  Returns all non-deleted notes in a specific folder for a user.
  Pass "" for root-level notes.
  """
  @spec list_notes_in_folder(map(), map(), String.t()) :: {:ok, [Note.t()]}
  def list_notes_in_folder(user, vault, folder) do
    {:ok, notes} =
      Repo.with_tenant(user.id, fn ->
        query =
          if folder == "" do
            # Root-level notes have folder = nil or ""
            from(n in Note,
              where:
                n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                  (is_nil(n.folder) or n.folder == ""),
              order_by: n.title
            )
          else
            from(n in Note,
              where:
                n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                  n.folder == ^folder,
              order_by: n.title
            )
          end

        Repo.all(query)
      end)

    {:ok, decrypt_if_needed(notes, user)}
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

    {:ok, notes} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                (n.folder == ^old_folder or
                   fragment("? LIKE ?", n.folder, ^(old_prefix <> "%"))),
            select: n
          )
        )
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
          decrypted_note = decrypt_if_needed(note, user)
          new_title = Helpers.extract_title(decrypted_note.content || "", new_path)

          {note.id, note.path, new_path, new_note_folder, new_title}
        end)

      Repo.with_tenant(user.id, fn ->
        Enum.each(updates, fn {id, _old_path, new_path, new_note_folder, new_title} ->
          from(n in Note, where: n.id == ^id)
          |> Repo.update_all(
            set: [
              path: new_path,
              folder: new_note_folder,
              title: new_title,
              embed_hash: nil,
              updated_at: now
            ]
          )
        end)
      end)

      # Insert soft-deleted tombstones for old paths so the HTTP changes feed
      # includes delete signals. Without these, polling clients retain stale
      # files at old paths after a folder rename.
      old_paths = Enum.map(updates, fn {_id, old_path, _new, _folder, _title} -> old_path end)

      mtime_float = DateTime.to_unix(now) + 0.0

      tombstones =
        Enum.map(old_paths, fn old_path ->
          %{
            path: old_path,
            content: "",
            title: "",
            folder: Helpers.extract_folder(old_path),
            tags: [],
            content_hash: "",
            mtime: mtime_float,
            user_id: user.id,
            vault_id: vault.id,
            created_at: now,
            updated_at: now,
            deleted_at: now
          }
        end)

      Repo.with_tenant(user.id, fn ->
        Repo.insert_all(Note, tombstones, on_conflict: :nothing)
      end)

      # Side effects outside the transaction — broadcast + reindex
      Enum.each(updates, fn {id, old_note_path, new_path, _folder, _title} ->
        Oban.insert(Engram.Workers.EmbedNote.new_debounced(id, old_path: old_note_path))
        broadcast_change(user.id, vault.id, "delete", old_note_path)
        broadcast_change(user.id, vault.id, "upsert", new_path)
      end)

      {:ok, length(notes)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp decrypt_if_needed(nil, _user), do: nil

  defp decrypt_if_needed(%Note{} = note, user) do
    case Engram.Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, decrypted} ->
        decrypted

      {:error, reason} ->
        Logger.error(
          "decrypt_failed user_id=#{user.id} note_id=#{note.id} reason=#{inspect(reason)}"
        )

        note
    end
  end

  defp decrypt_if_needed(notes, user) when is_list(notes) do
    Enum.map(notes, &decrypt_if_needed(&1, user))
  end

  # Like decrypt_if_needed but logs a warning on decrypt failure before returning
  # the original struct. Used before broadcast so operators know content is empty.
  defp decrypt_for_broadcast(%Note{} = note, user) do
    case Engram.Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, decrypted} ->
        decrypted

      {:error, reason} ->
        Logger.warning(
          "broadcast decrypt failed: user_id=#{user.id} note_id=#{note.id} reason=#{inspect(reason)}"
        )

        note
    end
  end

  defp validate_path(nil),
    do:
      {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}

  defp validate_path(""),
    do:
      {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}

  defp validate_path(path), do: {:ok, path}

  defp content_hash(content) do
    :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
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
    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    {path_ct, path_n} = Engram.Crypto.Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Engram.Crypto.Envelope.encrypt(folder, dek)

    Map.merge(attrs, %{
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Engram.Crypto.hmac_field(filter_key, path),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Engram.Crypto.hmac_field(filter_key, folder),
      tags_hmac: Enum.map(tags || [], &Engram.Crypto.hmac_field(filter_key, &1))
    })
  end
end
