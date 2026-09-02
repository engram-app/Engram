defmodule Engram.Indexing do
  @moduledoc """
  Orchestrates the parse → embed → upsert pipeline.

  Called from EmbedNote worker (async, after note upsert).
  Uses the configured embedder adapter and Qdrant client.
  """

  import Ecto.Query

  alias Engram.Indexing.IndexCap
  alias Engram.KeywordIndex
  alias Engram.Notes.Chunk
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Search.SearchProfile
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
  def index_note(note, %Engram.Vaults.Vault{} = vault, user \\ nil) do
    # Resolve identity ONCE for the whole call. This function and
    # prepare_index/3 below both need the same `%User{}`, and both used to
    # fetch it independently — on the embed path that made four `get_user!`
    # round trips for one note (here, prepare_index, and twice more in
    # EmbedNote). Measured 2.1 users/job in prod on 2026-08-28. The argument is
    # optional so the six test modules and any future caller can keep passing
    # two args; the hot path passes the user it already has.
    #
    # `_with_subscription`: everything downstream asks about a limit —
    # `IndexCap.within_cap?/2` and `SearchProfile.resolve/1` each resolve the
    # tier — and on a bare `get_user!/1` struct that is one `subscriptions`
    # query apiece. The join folds both into this fetch. See #1502.
    user = user || Engram.Accounts.get_user_with_subscription!(note.user_id)

    case prepare_index(note, vault, user) do
      {:ok, {:no_chunks, link_rows}} ->
        case Engram.Crypto.get_dek(user) do
          {:ok, _dek} ->
            # `:no_chunks` means this note must end up with ZERO index
            # artifacts, and it is reached two ways: the note was emptied, or
            # it fell outside the user's indexed-note cap. Both need the
            # PREVIOUS artifacts gone, and neither got that before — the
            # branch only wrote links and returned. A Pro->Free downgrade left
            # notes past the cap fully searchable with their dense vectors
            # intact, which is precisely the RAM the cap exists to reclaim.
            #
            # Errors PROPAGATE. Swallowing a failed Qdrant delete here would
            # let the caller stamp `embed_hash` and never revisit the note, so
            # the points it failed to remove would stay searchable forever.
            # Returning the error costs one Oban retry.
            with :ok <- purge_stale_index(note) do
              :ok = Engram.Links.replace_links(user, vault, note.id, link_rows)
              {:ok, 0}
            end

          {:error, :no_dek} = err ->
            emit_no_dek_telemetry(note)
            err
        end

      {:ok, prepared} ->
        commit_index(prepared)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Phase 1 of the indexing pipeline. Parses the note, calls the embedder, and
  builds the encrypted Qdrant payloads + chunk row inserts in memory.

  Performs **no** DB writes — safe to call without a transaction. Lets the
  slow Voyage AI HTTP call run outside any Postgres connection.

  Returns:
    * `{:ok, {:no_chunks, link_rows}}` — note has no parseable chunks; caller
      must still persist `link_rows` (a note emptied to "" must clear its
      stale outgoing edges, same as any other re-index)
    * `{:ok, prepared}` — ready to hand to `commit_index/1`
    * `{:error, reason}` — embed failed, encryption failed, etc.
  """
  def prepare_index(note, %Engram.Vaults.Vault{} = vault, user \\ nil) do
    link_rows = Engram.Links.Parser.extract(note.content || "")
    chunks = Markdown.parse(note.content || "", note.path)

    # An empty note needs no identity at all, so that branch stays ahead of the
    # fetch. Everything past it does: the cap check and the embed below both
    # want the same `%User{}`, and resolving it once here is what keeps this
    # path at one `users` query per note. See #1502.
    if chunks == [] do
      {:ok, {:no_chunks, link_rows}}
    else
      user = user || Engram.Accounts.get_user_with_subscription!(note.user_id)

      if IndexCap.within_cap?(note, user) do
        context_texts = Enum.map(chunks, & &1.context_text)
        dims = Application.get_env(:engram, :embed_dims, @default_dims)

        # Keyword-only tiers never call Voyage. `nil` vectors flow through
        # build_prepared/8, which emits a sparse-only named vector — the BM25
        # leg is computed locally from the chunk text, so keyword search is
        # fully functional with zero embedding spend.
        semantic? = SearchProfile.resolve(user).semantic

        with :ok <- Qdrant.ensure_collection(collection(), dims),
             {:ok, filter_key} <- Engram.Crypto.dek_filter_key(user),
             {:ok, vectors} <- maybe_embed(semantic?, context_texts) do
          avgdl = Engram.KeywordIndex.Stats.avgdl(note.vault_id)
          build_prepared(note, user, vault, chunks, vectors, filter_key, avgdl, link_rows)
        else
          {:error, :no_dek} = err ->
            emit_no_dek_telemetry(note)
            err

          other ->
            other
        end
      else
        # Outside the user's indexed-note cap: persist link rows (the graph is
        # not search and is not capped) but write no chunks and no Qdrant
        # points.
        {:ok, {:no_chunks, link_rows}}
      end
    end
  end

  # Guarded on chunk rows existing so the overwhelmingly common case (a note
  # that never had chunks) does not pay a Qdrant round trip on every index.
  # The cheap Postgres existence check gates the expensive remote delete.
  defp purge_stale_index(note) do
    if Repo.exists?(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true) do
      delete_note_index(note)
    else
      :ok
    end
  end

  # Shared with index_note/2's no_chunks branch: same [:engram, :indexing,
  # :encrypt_failed] counter either way, so "DEK missing at index time"
  # doesn't undercount just because the note happened to have no chunks.
  defp emit_no_dek_telemetry(note) do
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
  end

  @doc """
  Phase 2 of the indexing pipeline. Applies the prepared structure: deletes
  old Qdrant points + chunk rows, inserts the new ones, upserts Qdrant points.

  Caller is responsible for tenant context — non-tenant-scoped callers
  (e.g. `EmbedNote`) run as the superuser role and bypass RLS; tenant-scoped
  callers wrap this in a short `Repo.with_tenant/2`.

  Returns `{:ok, chunk_count}` or `{:error, reason}`.
  """
  def commit_index(%{
        note: note,
        user: user,
        vault: vault,
        chunk_rows: chunk_rows,
        qdrant_points: qdrant_points,
        links: link_rows
      }) do
    # Points first, by id, while the chunk rows still name them — a rename can
    # have retagged the note row, leaving the hmac filter below matching
    # nothing and the old points stranded. See `delete_points_for_note/1`.
    with :ok <- delete_points_for_note(note.id),
         :ok <-
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

      :ok = Engram.Links.replace_links(user, vault, note.id, link_rows)

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
    with :ok <- delete_points_for_note(note.id),
         :ok <-
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

  # Delete a note's Qdrant points by the ids recorded on its chunk rows.
  #
  # Runs BEFORE the chunk rows are dropped — once they are gone, nothing names
  # those points and no filter can find them again if the note's `path_hmac`
  # has drifted (rename → debounced repath → delete inside the window). This is
  # the delete that closes that hole; `delete_by_note/4` stays as the belt for
  # points whose rows were already lost.
  defp delete_points_for_note(note_id) do
    Chunk
    |> where([c], c.note_id == ^note_id)
    |> select([c], c.qdrant_point_id)
    |> Repo.all(skip_tenant_check: true)
    |> Enum.reject(&is_nil/1)
    |> then(&Qdrant.delete_points(collection(), &1))
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

  # `false` yields a nil vector per chunk. Kept as an explicit list (not a bare
  # nil) so build_prepared/8 can zip chunks with vectors either way.
  defp maybe_embed(false, texts), do: {:ok, Enum.map(texts, fn _ -> nil end)}
  defp maybe_embed(true, texts), do: embed_for_indexing(texts)

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
  defp build_prepared(note, user, vault, chunks, vectors, filter_key, avgdl, link_rows) do
    now = DateTime.utc_now(:second)

    # Language is a property of the NOTE, not of each chunk. Detecting per chunk
    # meant one full Lingua detector build per chunk (the NIF rebuilds the
    # detector on every call — deps/lingua/native/lingua_nif/src/lib.rs), i.e.
    # 8-38x the work for a normal note, and it was the single largest on-CPU
    # frame in prod during a bulk vault upload.
    #
    # Detecting once over the note body is also *more* accurate: lingua is far
    # more confident on a paragraph than on a one-line heading chunk. The
    # tradeoff is a mixed-language note now picks a single stemmer, which is
    # what the @floor confidence gate + raw-token fallback already assume.
    # Sample the CHUNKS, not `note.content`. `Markdown.parse/2` strips
    # frontmatter before chunking and re-appends the raw block as a synthetic
    # chunk at the END, so raw content can lead with a property block big enough
    # to fill detect/1's whole sample — and the language would then be decided by
    # YAML keys, for every chunk at once. Leading chunks are body prose.
    #
    # Bounded to a few chunks so a large note doesn't build a large throwaway
    # binary just to have detect/1 slice the front off it.
    # Reject by heading_path rather than trusting position: the frontmatter chunk
    # is appended last today, but a short note can have so few body chunks that a
    # positional take swallows it anyway (a one-section note has exactly two).
    # A note that is ONLY frontmatter then yields no sample and falls back to raw
    # token indexing, which is the right answer — YAML keys should not pick a
    # stemmer for prose that doesn't exist.
    language =
      chunks
      |> Enum.reject(&(&1.heading_path == "frontmatter"))
      |> Enum.take(3)
      |> Enum.map_join("\n\n", & &1.text)
      |> detect_language()

    prepared =
      Enum.zip(chunks, vectors)
      |> Enum.reduce_while({:ok, []}, fn {chunk, vector}, {:ok, acc} ->
        point_id = Ecto.UUID.generate()

        # One tokenization pass yields both the sparse vector and `doc_len`
        # (the raw token count, also persisted as `chunks.token_count`).
        {sparse, doc_len} =
          KeywordIndex.module().encode_document(chunk.text, filter_key, avgdl, language)

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
          tags_hmac: Enum.map(note.tags_hmac || [], &Base.encode64/1),
          type_hmac: encode_hmac(note.type_hmac),
          # Plaintext by design (spec 2026-07-02): dates are the only
          # unencrypted frontmatter fields, needed for range filters.
          fm_timestamp: note.fm_timestamp && DateTime.to_unix(note.fm_timestamp),
          fm_created: note.fm_created && DateTime.to_unix(note.fm_created)
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

            # Omit the dense named vector entirely when there is none —
            # Qdrant rejects a null vector, and a partial named-vector upsert
            # is the supported way to store sparse-only points.
            named_vectors =
              case vector do
                nil -> %{"keyword" => sparse}
                v -> %{"dense" => v, "keyword" => sparse}
              end

            point = %{
              id: point_id,
              vector: named_vectors,
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
                reason: Engram.Logger.Metadata.safe_reason(reason)
              }
            )

            {:halt, err}
        end
      end)

    with {:ok, prepared_pairs} <- prepared do
      {chunk_rows, qdrant_points} = prepared_pairs |> Enum.reverse() |> Enum.unzip()

      {:ok,
       %{
         note: note,
         user: user,
         vault: vault,
         chunk_rows: chunk_rows,
         qdrant_points: qdrant_points,
         links: link_rows
       }}
    end
  end

  # Encodes a Phase B HMAC binary as base64 for JSON-safe Qdrant payload.
  # Returns nil for nil — leaves the field absent so legacy/un-backfilled
  # rows don't poison filters with a fake hmac.
  defp encode_hmac(nil), do: nil
  defp encode_hmac(bin) when is_binary(bin), do: Base.encode64(bin)

  defp detect_language(text), do: Engram.KeywordIndex.LangDetect.detect(text)
end
