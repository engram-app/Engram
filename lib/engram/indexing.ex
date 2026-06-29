defmodule Engram.Indexing do
  @moduledoc """
  Orchestrates the parse → embed → upsert pipeline.

  Called from EmbedNote worker (async, after note upsert).
  Uses the configured embedder adapter and Qdrant client.
  """

  import Ecto.Query

  alias Engram.KeywordIndex
  alias Engram.KeywordIndex.Tokenizer
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
  def prepare_index(note, %Engram.Vaults.Vault{} = _vault) do
    chunks = Markdown.parse(note.content || "", note.path)

    if chunks == [] do
      {:ok, :no_chunks}
    else
      context_texts = Enum.map(chunks, & &1.context_text)
      dims = Application.get_env(:engram, :embed_dims, @default_dims)
      user = Engram.Accounts.get_user!(note.user_id)

      with :ok <- Qdrant.ensure_collection(collection(), dims),
           {:ok, filter_key} <- Engram.Crypto.dek_filter_key(user),
           {:ok, vectors} <- embed_for_indexing(context_texts) do
        avgdl = Engram.KeywordIndex.Stats.avgdl(note.vault_id)
        build_prepared(note, user, chunks, vectors, filter_key, avgdl)
      else
        {:error, :no_dek} = err ->
          :telemetry.execute(
            [:engram, :indexing, :encrypt_failed],
            %{count: 1},
            %{
              user_id: note.user_id,
              vault_id: note.vault_id,
              note_id: note.id,
              reason: :no_dek
            }
          )

          err

        other ->
          other
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
             encode_hmac(note.path_hmac)
           ) do
      # skip_tenant_check: trusted internal pipeline, already scoped by note_id/user_id
      _ =
        Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)

      _ = Repo.insert_all(Chunk, chunk_rows, skip_tenant_check: true)

      # Bounded upsert bodies: thousands of 1024-dim float vectors as one
      # JSON PUT is tens of MB; Qdrant handles batches fine but the single
      # request does not.
      qdrant_points
      |> Enum.chunk_every(256)
      |> Enum.reduce_while(:ok, fn batch, :ok ->
        case Qdrant.upsert_points(collection(), batch) do
          :ok -> {:cont, :ok}
          other -> {:halt, other}
        end
      end)
      |> case do
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
  Re-path a note's Qdrant points after a rename (#746): overwrite the
  `path_hmac`/`folder_hmac` payload keys on the points still filed under
  `old_path_hmac` with the note row's CURRENT (post-rename) hmacs. Vectors,
  sparse vectors, and encrypted payload fields are untouched — no Voyage call.
  """
  def repath_points(note, old_path_hmac) do
    Qdrant.set_payload_by_filter(
      collection(),
      to_string(note.user_id),
      to_string(note.vault_id),
      old_path_hmac,
      %{
        "path_hmac" => encode_hmac(note.path_hmac),
        "folder_hmac" => encode_hmac(note.folder_hmac)
      }
    )
  end

  @doc """
  Exact count of a note's Qdrant points under `path_hmac` (#746). Used by the
  repath worker to branch between PATCH, re-embed self-heal, and the
  embedded-but-missing inconsistency warning.
  """
  def count_points_by_path_hmac(note, path_hmac) do
    Qdrant.count_by_note(
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

  # Voyage caps inputs per request (1,000 texts / token budget); a large
  # note's chunks in ONE call is a guaranteed 4xx no retry can fix — the
  # job then churns through ReconcileEmbeddings forever. 128 matches the
  # documented batch sweet spot and stays far below every API limit.
  @embed_batch_size 128

  defp embed_for_indexing(texts) do
    texts
    |> Enum.chunk_every(@embed_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case do_embed_batch(batch) do
        {:ok, vectors} -> {:cont, {:ok, [vectors | acc]}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {:ok, reversed_batches} ->
        {:ok, reversed_batches |> Enum.reverse() |> Enum.concat()}

      other ->
        other
    end
  end

  defp do_embed_batch(texts) do
    case doc_embed_model() do
      nil -> embedder().embed_texts(texts)
      model -> embedder().embed_texts(texts, model: model)
    end
  end

  # Encrypt-first: build payloads + encrypt in memory BEFORE any mutation.
  # If any chunk's encryption fails, no Postgres row or Qdrant point is touched
  # and prior state survives for the next Oban retry.
  defp build_prepared(note, user, chunks, vectors, filter_key, avgdl) do
    now = DateTime.utc_now(:second)

    prepared =
      Enum.zip(chunks, vectors)
      |> Enum.reduce_while({:ok, []}, fn {chunk, vector}, {:ok, acc} ->
        point_id = Ecto.UUID.generate()

        doc_len = chunk.text |> Tokenizer.tokens(nil) |> length()
        language = detect_language(chunk.text)

        sparse =
          KeywordIndex.module().encode_document(chunk.text, filter_key, doc_len, avgdl, language)

        base_payload = %{
          user_id: to_string(note.user_id),
          vault_id: to_string(note.vault_id),
          title: note.title,
          heading_path: chunk.heading_path,
          text: chunk.text,
          chunk_index: chunk.position,
          # #590: source_path/folder/tags plaintext intentionally NOT stored.
          # Qdrant Cloud is a separate breach surface; the cleartext leaked
          # every user's folder tree + tags. Display values (path/title/tags)
          # are rehydrated from the `notes` row at search time, keyed by the
          # chunk's note_id. The *_hmac fields below carry all filter load
          # (folder/tags/path scoping) without exposing plaintext.
          path_hmac: encode_hmac(note.path_hmac),
          folder_hmac: encode_hmac(note.folder_hmac),
          tags_hmac: Enum.map(note.tags_hmac || [], &Base.encode64/1)
        }

        case Engram.Crypto.encrypt_qdrant_payload(base_payload, user, collection(), point_id) do
          {:ok, payload} ->
            row = %{
              note_id: note.id,
              user_id: note.user_id,
              vault_id: note.vault_id,
              position: chunk.position,
              heading_path: chunk.heading_path,
              char_start: chunk.char_start,
              char_end: chunk.char_end,
              token_count: doc_len,
              qdrant_point_id: point_id,
              created_at: now
            }

            point = %{
              id: point_id,
              vector: %{"dense" => vector, "keyword" => sparse},
              payload: payload
            }

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

    with {:ok, prepared_pairs} <- prepared do
      {chunk_rows, qdrant_points} = prepared_pairs |> Enum.reverse() |> Enum.unzip()
      {:ok, %{note: note, chunk_rows: chunk_rows, qdrant_points: qdrant_points}}
    end
  end

  # Encodes a Phase B HMAC binary as base64 for JSON-safe Qdrant payload.
  # Returns nil for nil — leaves the field absent so legacy/un-backfilled
  # rows don't poison filters with a fake hmac.
  defp encode_hmac(nil), do: nil
  defp encode_hmac(bin) when is_binary(bin), do: Base.encode64(bin)

  defp detect_language(text), do: Engram.KeywordIndex.LangDetect.detect(text)
end
