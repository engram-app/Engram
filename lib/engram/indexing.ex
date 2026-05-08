defmodule Engram.Indexing do
  @moduledoc """
  Orchestrates the parse → embed → upsert pipeline.

  Called from EmbedNote worker (async, after note upsert).
  Uses the configured embedder adapter and Qdrant client.
  """

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Vector.Qdrant

  @default_dims 1024

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "obsidian_notes")
  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  @doc """
  Full pipeline for a note: parse → embed → delete old chunks → upsert new chunks.
  Returns `{:ok, chunk_count}` or `{:error, reason}`.

  Takes the note's vault for Qdrant tenant scoping. Phase B.4: payload
  encryption is mandatory and unconditional — every Qdrant point's
  `text/title/heading_path` is replaced with `*_ciphertext + *_nonce`.

  Internally calls `prepare_index/2` (HTTP/CPU only, no DB writes) followed by
  `commit_index/1` (DB + Qdrant writes). Workers that need to keep the slow
  embedding call outside a transaction can call those two directly and run the
  commit step inside a per-note `Repo.with_tenant/2`.
  """
  def index_note(note, %Engram.Vaults.Vault{} = vault) do
    case prepare_index(note, vault) do
      {:ok, :no_chunks} -> {:ok, 0}
      {:ok, prepared} -> commit_index(prepared)
      {:error, _} = err -> err
    end
  end

  @doc """
  Phase 1 of the indexing pipeline. Parses the note, calls the embedder, and
  builds the encrypted Qdrant payloads + chunk row inserts in memory.

  Performs **no** DB writes — safe to call without a transaction. Lets the
  slow Voyage AI HTTP call run outside any Postgres connection.

  Returns:
    * `{:ok, :no_chunks}` — note has no parseable chunks
    * `{:ok, prepared}` — ready to hand to `commit_index/1`
    * `{:error, reason}` — embed failed, encryption failed, etc.
  """
  def prepare_index(note, %Engram.Vaults.Vault{} = vault) do
    chunks = Markdown.parse(note.content || "", note.path)

    if chunks == [] do
      {:ok, :no_chunks}
    else
      context_texts = Enum.map(chunks, & &1.context_text)
      dims = Application.get_env(:engram, :embed_dims, @default_dims)

      with :ok <- Qdrant.ensure_collection(collection(), dims),
           {:ok, vectors} <- embed_for_indexing(context_texts),
           {:ok, prepared} <- build_prepared(note, vault, chunks, vectors) do
        {:ok, prepared}
      end
    end
  end

  @doc """
  Phase 2 of the indexing pipeline. Applies the prepared structure: deletes
  old Qdrant points + chunk rows, inserts the new ones, upserts Qdrant points.

  Caller is responsible for tenant context — non-tenant-scoped callers
  (e.g. `EmbedNote`) run as the superuser role and bypass RLS; tenant-scoped
  callers wrap this in a short `Repo.with_tenant/2`.

  Returns `{:ok, chunk_count}` or `{:error, reason}`.
  """
  def commit_index(%{note: note, chunk_rows: chunk_rows, qdrant_points: qdrant_points}) do
    with :ok <-
           Qdrant.delete_by_note(
             collection(),
             to_string(note.user_id),
             to_string(note.vault_id),
             note.path
           ) do
      # skip_tenant_check: trusted internal pipeline, already scoped by note_id/user_id
      Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)
      Repo.insert_all(Chunk, chunk_rows, skip_tenant_check: true)

      case Qdrant.upsert_points(collection(), qdrant_points) do
        :ok -> {:ok, length(chunk_rows)}
        other -> other
      end
    end
  end

  @doc """
  Delete Qdrant points for a specific path-hmac (used after rename to clean
  up old path's points). T3.2 — `path_hmac` is the base64-encoded HMAC of
  the note path; carrying plaintext path through Oban args defeats Phase B
  encryption for the rename window.
  """
  def delete_points_by_path_hmac(note, path_hmac) do
    Qdrant.delete_by_note(
      collection(),
      to_string(note.user_id),
      to_string(note.vault_id),
      path_hmac
    )
  end

  @doc """
  Remove all indexed data for a note (Qdrant points first, then Postgres
  chunks). T3.2 — Qdrant filter keys off `path_hmac` (base64), not plaintext
  `source_path`. The note row's `path_hmac` is the source of truth.
  """
  def delete_note_index(note) do
    with :ok <-
           Qdrant.delete_by_note(
             collection(),
             to_string(note.user_id),
             to_string(note.vault_id),
             encode_hmac(note.path_hmac)
           ) do
      Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp doc_embed_model, do: Application.get_env(:engram, :doc_embed_model)

  defp embed_for_indexing(texts) do
    case doc_embed_model() do
      nil -> embedder().embed_texts(texts)
      model -> embedder().embed_texts(texts, model: model)
    end
  end

  # Encrypt-first: build payloads + encrypt in memory BEFORE any mutation.
  # If any chunk's encryption fails, no Postgres row or Qdrant point is touched
  # and prior state survives for the next Oban retry.
  defp build_prepared(note, _vault, chunks, vectors) do
    user = Engram.Accounts.get_user!(note.user_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    prepared =
      Enum.zip(chunks, vectors)
      |> Enum.reduce_while({:ok, []}, fn {chunk, vector}, {:ok, acc} ->
        point_id = Ecto.UUID.generate()

        base_payload = %{
          user_id: to_string(note.user_id),
          vault_id: to_string(note.vault_id),
          source_path: note.path,
          title: note.title,
          folder: note.folder || "",
          tags: note.tags || [],
          heading_path: chunk.heading_path,
          text: chunk.text,
          chunk_index: chunk.position,
          # Phase B.2.4 (additive): write hmacs alongside plaintext so the
          # B.2.5 backfill worker has a target shape and B.2.3 read switch
          # can flip atomically once existing points are rewritten.
          path_hmac: encode_hmac(note.path_hmac),
          folder_hmac: encode_hmac(note.folder_hmac),
          tags_hmac: Enum.map(note.tags_hmac || [], &Base.encode64/1)
        }

        case Engram.Crypto.encrypt_qdrant_payload(base_payload, user) do
          {:ok, payload} ->
            row = %{
              note_id: note.id,
              user_id: note.user_id,
              vault_id: note.vault_id,
              position: chunk.position,
              heading_path: chunk.heading_path,
              char_start: chunk.char_start,
              char_end: chunk.char_end,
              qdrant_point_id: point_id,
              created_at: now
            }

            point = %{id: point_id, vector: vector, payload: payload}
            {:cont, {:ok, [{row, point} | acc]}}

          {:error, reason} = err ->
            :telemetry.execute(
              [:engram, :indexing, :encrypt_failed],
              %{count: 1},
              %{
                user_id: note.user_id,
                vault_id: note.vault_id,
                note_id: note.id,
                reason: inspect(reason)
              }
            )

            {:halt, err}
        end
      end)

    with {:ok, prepared_pairs} <- prepared,
         {chunk_rows, qdrant_points} = prepared_pairs |> Enum.reverse() |> Enum.unzip() do
      {:ok, %{note: note, chunk_rows: chunk_rows, qdrant_points: qdrant_points}}
    end
  end

  # Encodes a Phase B HMAC binary as base64 for JSON-safe Qdrant payload.
  # Returns nil for nil — leaves the field absent so legacy/un-backfilled
  # rows don't poison filters with a fake hmac.
  defp encode_hmac(nil), do: nil
  defp encode_hmac(bin) when is_binary(bin), do: Base.encode64(bin)
end
