defmodule Engram.Indexing do
  @moduledoc """
  Orchestrates the parse → embed → upsert pipeline.

  Called from EmbedNote worker (async, after note upsert).
  Uses the configured embedder adapter and Qdrant client.
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Indexing.IndexCap
  alias Engram.KeywordIndex
  alias Engram.Logger.Metadata
  alias Engram.Notes.Chunk
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Search.SearchProfile
  alias Engram.Vector.Qdrant

  require Logger

  @default_dims 1024

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "obsidian_notes")
  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  @doc """
  Full pipeline for a note: parse → diff against the chunks already indexed →
  embed only the ones whose text changed → apply. Returns `{:ok, chunk_count}`
  (the note's total chunk count, reused or not) or `{:error, reason}`.

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
        case Crypto.get_dek(user) do
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
        dims = Application.get_env(:engram, :embed_dims, @default_dims)

        # Keyword-only tiers never call Voyage. `nil` vectors flow through
        # build_prepared/8, which emits a sparse-only named vector — the BM25
        # leg is computed locally from the chunk text, so keyword search is
        # fully functional with zero embedding spend.
        semantic? = SearchProfile.resolve(user).semantic

        with :ok <- Qdrant.ensure_collection(collection(), dims),
             {:ok, filter_key} <- Crypto.dek_filter_key(user),
             {:ok, content_key} <- Crypto.dek_content_hash_key(user),
             plan = plan_chunks(note, chunks, content_key),
             texts = embed_texts(plan),
             {:ok, vectors} <- maybe_embed(semantic?, texts),
             :ok <- ensure_one_vector_per_text(vectors, texts, note) do
          avgdl = Engram.KeywordIndex.Stats.avgdl(note.vault_id)
          build_prepared(note, user, vault, plan, vectors, filter_key, avgdl, link_rows)
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
  Phase 2 of the indexing pipeline. Applies the prepared structure: upserts the
  points for chunks that changed, PATCHes the note-level payload onto the ones
  being reused, rewrites the chunk rows, and deletes the points nothing names
  any more.

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
        links: link_rows,
        reused_point_ids: reused_point_ids,
        stale_point_ids: stale_point_ids,
        note_payload: note_payload
      }) do
    # Ordered so that every failure leaves STRAY points (which OrphanSweep
    # reaps) rather than a chunk row naming a point that is already gone —
    # which nothing self-heals and which reads as silently missing content.
    # That means the stale delete goes LAST, after the rows stop naming those
    # points. Deleting first and crashing before the row write would leave the
    # next attempt happily "reusing" ids that no longer exist in Qdrant.
    with :ok <- purge_before_rebuild(note, reused_point_ids),
         :ok <- upsert_points_batched(qdrant_points),
         # Reused points keep their vectors AND their ciphertext (every
         # encrypted field is inside `context_text`, so an equal hmac means an
         # identical payload), but the note-level filter keys on them are
         # note-level: a frontmatter tag edit changes ONE chunk while every
         # other point still answers tag filters with the pre-edit tags. One
         # PATCH refreshes the lot — the values are identical across a note's
         # points, which is why `chunk_index` no longer lives in the payload.
         :ok <- Qdrant.set_payload(collection(), reused_point_ids, note_payload) do
      # skip_tenant_check: trusted internal pipeline, already scoped by note_id/user_id
      #
      # Wholesale rewrite rather than a row-level diff: the rows are local and
      # cheap, and replacing them all sidesteps every ordering problem with
      # `chunks_note_id_position_index` when positions shift. One transaction
      # so OrphanSweep can never scroll a live point during the window where
      # its row is momentarily absent.
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)
          Repo.insert_all(Chunk, chunk_rows, skip_tenant_check: true)
        end)

      :ok = Engram.Links.replace_links(user, vault, note.id, link_rows)

      drop_stale_points(reused_point_ids, stale_point_ids, note)

      {:ok, length(chunk_rows)}
    end
  end

  # Bounded upsert bodies: thousands of 1024-dim float vectors as one JSON PUT
  # is tens of MB; Qdrant handles batches fine but the single request does not.
  defp upsert_points_batched(points) do
    points
    |> Enum.chunk_every(256)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Qdrant.upsert_points(collection(), batch) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  # Nothing reusable — every chunk is being rebuilt, so keep the belt-and-
  # braces purge this path has always run: by point id, AND by the path_hmac
  # filter, which is the only thing that reaches points whose chunk rows were
  # lost (a Postgres restore rolled back past the embed that wrote them).
  #
  # The reuse path cannot run that filter: it matches the note's points
  # wholesale, including the ones being kept. It relies on `OrphanSweep`'s
  # point pass for that class instead, which is the same reconciliation on a
  # weekly tick rather than per index.
  defp purge_before_rebuild(note, []), do: delete_note_points(note)
  defp purge_before_rebuild(_note, _reused), do: :ok

  # Already handled wholesale by `purge_before_rebuild/2`.
  defp drop_stale_points([], _stale, _note), do: :ok

  defp drop_stale_points(_reused, stale, note) do
    case Qdrant.delete_points(collection(), stale) do
      :ok ->
        :ok

      other ->
        # The index itself is correct; what survives is a stray carrying
        # deleted content, still searchable until OrphanSweep reaps it. Do NOT
        # return an error: the rows are already committed and no longer name
        # these ids, so a retry cannot find them again — it would only redo
        # correct work. Count it so a rising rate is visible.
        # No ids in the metadata: `Engram.PromEx.Indexing` turns this into a
        # metric, and that module's cardinality contract forbids note/user/
        # vault tags. Per-note detail belongs in the log line below.
        :telemetry.execute(
          [:engram, :indexing, :stale_points_leaked],
          %{count: length(stale)},
          %{}
        )

        Logger.warning(
          "indexing_stale_points_leaked",
          Metadata.with_category(:warning, :search,
            user_id: note.user_id,
            vault_id: note.vault_id,
            note_id: note.id,
            total_count: length(stale),
            reason: Metadata.safe_reason(other)
          )
        )

        :ok
    end
  end

  @doc """
  Delete Qdrant points for a specific path-hmac (used after rename to clean
  up old path's points). T3.2 — `path_hmac` is the base64-encoded HMAC of
  the note path; carrying plaintext path through Oban args defeats Phase B
  encryption for the rename window.

  Also drops the note's chunk-reuse markers. This filter deletes points that
  the note's chunk rows still name, and a same-folder rename of a note with a
  heading leaves every `context_text` identical — so the re-index that follows
  would happily "reuse" the ids this call just removed and leave the note
  silently unsearchable. Forgetting the markers costs one full re-embed of a
  note that was about to pay for one anyway.
  """
  def delete_points_by_path_hmac(note, path_hmac) do
    with :ok <-
           Qdrant.delete_by_note(
             collection(),
             to_string(note.user_id),
             to_string(note.vault_id),
             path_hmac
           ) do
      forget_chunk_reuse(note.id)
      :ok
    end
  end

  @doc """
  Clears every chunk-reuse fingerprint owned by a user, forcing a full rebuild
  on the next index of each of their notes.

  The invariant behind `context_hmac` is that a marker only survives while the
  point it names does. Any path that removes a user's Qdrant points **without**
  removing their chunk rows breaks it, and the break is silent: the next index
  reuses ids that are no longer in Qdrant and the note goes unsearchable with
  no error anywhere.

  `Accounts.Lifecycle.soft_delete/2` is such a path — it drops the points and
  leaves the rows for the later hard-delete sweep. No code today un-soft-deletes
  an account, so this is a guard rather than a live fix, but the cost is one
  UPDATE on a path that runs once per account and the failure it prevents is
  invisible.
  """
  def forget_chunk_reuse_for_user(user_id) do
    Repo.update_all(
      from(c in Chunk, where: c.user_id == ^user_id and not is_nil(c.context_hmac)),
      [set: [context_hmac: nil]],
      skip_tenant_check: true
    )

    :ok
  end

  # Clears the reuse fingerprints for a note, forcing its next index to rebuild
  # every chunk. `nil` is the same "cannot be matched" state a row written
  # before the column existed is in.
  defp forget_chunk_reuse(note_id) do
    Repo.update_all(
      from(c in Chunk, where: c.note_id == ^note_id and not is_nil(c.context_hmac)),
      [set: [context_hmac: nil]],
      skip_tenant_check: true
    )

    :ok
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
    with :ok <- delete_note_points(note) do
      Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)
      :ok
    end
  end

  # Every Qdrant point a note could own, removed two ways.
  #
  # By id first, while the chunk rows still name them — a rename can have
  # retagged the note row, leaving the hmac filter below matching nothing and
  # the old points stranded. See `delete_points_for_note/1`. The filter then
  # catches the reverse case: points whose rows are already gone.
  defp delete_note_points(note) do
    with :ok <- delete_points_for_note(note.id) do
      Qdrant.delete_by_note(
        collection(),
        to_string(note.user_id),
        to_string(note.vault_id),
        encode_hmac(note.path_hmac)
      )
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

  # Voyage caps a request two ways: 1,000 texts AND 120,000 tokens summed over
  # them. Blowing either is a 400 no retry can fix, so the job churns through
  # ReconcileEmbeddings forever.
  #
  # A count alone does not bound the token sum, because tokens per byte vary
  # with the content. 128 chunks of ~2KB is ~269KB, which is ~67K tokens of
  # English (fine) but ~134K of base64 or minified text (over the limit) — and
  # dense, space-free content is exactly what the chunker's size cap now slices
  # into full-width chunks. So bound the bytes too.
  #
  # The byte ceiling is 120KB, and it is NOT a density estimate. A previous
  # version of this comment picked 200KB as "100K tokens at 2 bytes/token, the
  # worst density we expect" — prod disproved it within a day. Six notes from
  # one import kept failing with `batch has 143526 tokens after truncation`
  # against the 120,000 ceiling; a batch of at most 200,000 bytes producing
  # 143,526 tokens is 1.39 bytes/token, well under the assumed floor of 2.
  #
  # So do not guess the density. A token never spans less than one byte, so a
  # batch bounded at 120,000 BYTES is bounded at 120,000 tokens for any content
  # and any tokenizer — no assumption left to be wrong a third time.
  #
  # This costs requests, not money: Voyage bills tokens, and ordinary English
  # (~4 bytes/token) now packs ~30K tokens per request instead of filling the
  # allowance. These are background Oban jobs, so the extra round trips are
  # cheaper than another poison loop.
  @embed_batch_size 128
  @embed_batch_bytes 120_000

  # `false` yields a nil vector per chunk. Kept as an explicit list (not a bare
  # nil) so build_prepared/8 can zip chunks with vectors either way.
  defp maybe_embed(false, texts), do: {:ok, Enum.map(texts, fn _ -> nil end)}
  defp maybe_embed(true, texts), do: embed_for_indexing(texts)

  defp embed_for_indexing(texts) do
    texts
    |> batch_texts()
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

  # Close a batch on whichever ceiling comes first, count or bytes. A single
  # text wider than the byte budget still goes out alone rather than looping:
  # the chunker caps it long before here, and dropping it would silently
  # unindex the content.
  defp batch_texts(texts) do
    Enum.chunk_while(
      texts,
      {[], 0, 0},
      fn text, {batch, count, bytes} ->
        size = byte_size(text)

        if batch != [] and
             (count + 1 > @embed_batch_size or bytes + size > @embed_batch_bytes) do
          {:cont, Enum.reverse(batch), {[text], 1, size}}
        else
          {:cont, {[text | batch], count + 1, bytes + size}}
        end
      end,
      fn
        {[], _count, _bytes} -> {:cont, {[], 0, 0}}
        {batch, _count, _bytes} -> {:cont, Enum.reverse(batch), {[], 0, 0}}
      end
    )
  end

  defp do_embed_batch(texts) do
    case doc_embed_model() do
      nil -> embedder().embed_texts(texts)
      model -> embedder().embed_texts(texts, model: model)
    end
  end

  # Decides, per chunk, whether it can keep the point it already has (#1592).
  #
  # The fingerprint is over `context_text` — the exact string the embedder is
  # given ("folder > title > heading\n\ntext") — NOT the bare chunk text. That
  # distinction is the whole correctness argument: an equal `context_text`
  # means the dense vector, the sparse vector, `token_count`, and all three
  # encrypted payload fields (`text`, `title`, `heading_path`, all of which are
  # inside it) are reusable verbatim. Hashing the bare text instead would
  # preserve a vector built under a stale title or folder.
  #
  # `position` and the char offsets are deliberately NOT in the hash. Inserting
  # a paragraph shifts every later chunk's offsets while leaving its text
  # identical, and that is exactly the case reuse exists to catch.
  #
  # Matched by multiplicity, not by set membership: a note with two identical
  # sections has two rows under one hmac and must consume one point each, or
  # the second chunk silently adopts the first one's point.
  defp plan_chunks(note, chunks, content_key) do
    chunks =
      Enum.map(chunks, fn chunk ->
        Map.put(chunk, :context_hmac, Crypto.hmac_content_hash(content_key, chunk.context_text))
      end)

    existing =
      Chunk
      |> where([c], c.note_id == ^note.id)
      |> select([c], {c.context_hmac, c.qdrant_point_id, c.token_count})
      |> Repo.all(skip_tenant_check: true)
      |> Enum.reject(fn {_hmac, point_id, _tokens} -> is_nil(point_id) end)

    # A nil hmac is a row written before the column existed, or one whose key
    # a DEK rotation invalidated. It names a real point that still has to be
    # cleaned up, so it stays in `existing` — it just can never be matched.
    by_hmac =
      existing
      |> Enum.reject(fn {hmac, _point_id, _tokens} -> is_nil(hmac) end)
      |> Enum.group_by(
        fn {hmac, _point_id, _tokens} -> hmac end,
        fn {_hmac, point_id, tokens} -> {point_id, tokens} end
      )

    {entries, _left} =
      Enum.map_reduce(chunks, by_hmac, fn chunk, acc ->
        case Map.get(acc, chunk.context_hmac) do
          [{point_id, tokens} | rest] ->
            {{:reuse, chunk, point_id, tokens}, Map.put(acc, chunk.context_hmac, rest)}

          _none ->
            {{:embed, chunk}, acc}
        end
      end)

    reused = for {:reuse, _chunk, point_id, _tokens} <- entries, do: point_id

    %{
      entries: entries,
      reused_point_ids: reused,
      stale_point_ids: Enum.map(existing, fn {_h, id, _t} -> id end) -- reused
    }
  end

  defp embed_texts(plan), do: for({:embed, chunk} <- plan.entries, do: chunk.context_text)

  # The embedder contract (`Engram.Embedder.embed_texts/1`) promises a vector
  # list but not that it is the same length as the input, and the Voyage
  # adapter maps whatever `data` the API returned without counting it.
  #
  # This used to be absorbed silently: `Enum.zip(chunks, vectors)` truncated to
  # the shorter list, so a short response indexed only the leading chunks and
  # the caller still stamped `embed_hash` — a permanently half-indexed note
  # with nothing to signal it. Fail the attempt instead. Oban retries, and
  # `ReconcileEmbeddings` picks the note up if the retries run out.
  defp ensure_one_vector_per_text(vectors, texts, note) do
    got = length(vectors)
    want = length(texts)

    if got == want do
      :ok
    else
      Logger.error(
        "embed_vector_count_mismatch",
        Metadata.with_category(:error, :search,
          user_id: note.user_id,
          vault_id: note.vault_id,
          note_id: note.id,
          result: %{got: got, want: want}
        )
      )

      {:error, {:embed_count_mismatch, got, want}}
    end
  end

  defp entry_chunk({:reuse, chunk, _point_id, _tokens}), do: chunk
  defp entry_chunk({:embed, chunk}), do: chunk

  # Encrypt-first: build payloads + encrypt in memory BEFORE any mutation.
  # If any chunk's encryption fails, no Postgres row or Qdrant point is touched
  # and prior state survives for the next Oban retry.
  defp build_prepared(note, user, vault, plan, vectors, filter_key, avgdl, link_rows) do
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
      plan.entries
      |> Enum.map(&entry_chunk/1)
      |> Enum.reject(&(&1.heading_path == "frontmatter"))
      |> Enum.take(3)
      |> Enum.map_join("\n\n", & &1.text)
      |> detect_language()

    note_payload = note_payload(note)
    ctx = {note, user, note_payload, filter_key, avgdl, language, now}

    prepared =
      Enum.reduce_while(plan.entries, {:ok, [], vectors}, fn entry, {:ok, acc, pending} ->
        case build_entry(entry, ctx, pending) do
          {:ok, built, rest} -> {:cont, {:ok, [built | acc], rest}}
          {:error, _reason} = err -> {:halt, err}
        end
      end)

    with {:ok, reversed, _spent} <- prepared do
      built = Enum.reverse(reversed)

      {:ok,
       %{
         note: note,
         user: user,
         vault: vault,
         chunk_rows: Enum.map(built, & &1.row),
         qdrant_points: for(%{point: p} <- built, p != nil, do: p),
         # Straight from the plan, not re-derived from `built`. Two independent
         # derivations of the same list is how "reused" and "not deleted" drift
         # apart, and the drift is silent: an id in one list but not the other
         # is either a stray or a row pointing at nothing.
         reused_point_ids: plan.reused_point_ids,
         stale_point_ids: plan.stale_point_ids,
         note_payload: note_payload,
         links: link_rows
       }}
    end
  end

  # A reused chunk costs nothing but a row: no embed, no tokenizer pass, no
  # encryption. Its `token_count` rides along from the row it replaces rather
  # than being recomputed from text that has not changed.
  defp build_entry({:reuse, chunk, point_id, tokens}, {note, _u, _p, _fk, _a, _l, now}, pending) do
    {:ok, %{row: chunk_row(note, chunk, point_id, tokens, now), point: nil}, pending}
  end

  defp build_entry({:embed, chunk}, ctx, [vector | rest]) do
    {note, user, note_payload, filter_key, avgdl, language, now} = ctx
    point_id = Ecto.UUID.generate()

    # One tokenization pass yields both the sparse vector and `doc_len`
    # (the raw token count, also persisted as `chunks.token_count`).
    {sparse, doc_len} =
      KeywordIndex.module().encode_document(chunk.text, filter_key, avgdl, language)

    # `chunk_index` used to live here. Nothing ever read it, and dropping it is
    # what lets a reused point be refreshed for the whole note in ONE
    # `set_payload` — with a per-chunk key in the payload, every reused point
    # would need its own call. See `commit_index/1`.
    base_payload =
      Map.merge(note_payload, %{
        title: note.title,
        heading_path: chunk.heading_path,
        text: chunk.text
      })

    case Crypto.encrypt_qdrant_payload(base_payload, user, collection(), point_id) do
      {:ok, payload} ->
        # Omit the dense named vector entirely when there is none — Qdrant
        # rejects a null vector, and a partial named-vector upsert is the
        # supported way to store sparse-only points.
        named_vectors =
          case vector do
            nil -> %{"keyword" => sparse}
            v -> %{"dense" => v, "keyword" => sparse}
          end

        built = %{
          row: chunk_row(note, chunk, point_id, doc_len, now),
          point: %{id: point_id, vector: named_vectors, payload: payload}
        }

        {:ok, built, rest}

      {:error, reason} = err ->
        :telemetry.execute(
          [:engram, :indexing, :encrypt_failed],
          %{count: 1},
          %{
            user_id: note.user_id,
            vault_id: note.vault_id,
            note_id: note.id,
            reason: Metadata.safe_reason(reason)
          }
        )

        err
    end
  end

  defp chunk_row(note, chunk, point_id, token_count, now) do
    %{
      note_id: note.id,
      user_id: note.user_id,
      vault_id: note.vault_id,
      position: chunk.position,
      heading_path: chunk.heading_path,
      char_start: chunk.char_start,
      char_end: chunk.char_end,
      token_count: token_count,
      qdrant_point_id: point_id,
      context_hmac: chunk.context_hmac,
      created_at: now
    }
  end

  # The slice of a Qdrant payload that is a property of the NOTE rather than of
  # the chunk — identical across every point the note owns, which is what makes
  # refreshing a reused point a single call.
  #
  # #590: source_path/folder/tags plaintext intentionally NOT stored. Qdrant
  # Cloud is a separate breach surface; the cleartext leaked every user's folder
  # tree + tags. Display values (path/title/tags) are rehydrated from the
  # `notes` row at search time, keyed by the chunk's note_id. The *_hmac fields
  # carry all filter load (folder/tags/path scoping) without exposing plaintext.
  defp note_payload(note) do
    %{
      user_id: to_string(note.user_id),
      vault_id: to_string(note.vault_id),
      path_hmac: encode_hmac(note.path_hmac),
      folder_hmac: encode_hmac(note.folder_hmac),
      tags_hmac: Enum.map(note.tags_hmac || [], &Base.encode64/1),
      type_hmac: encode_hmac(note.type_hmac),
      # Plaintext by design (spec 2026-07-02): dates are the only unencrypted
      # frontmatter fields, needed for range filters.
      fm_timestamp: note.fm_timestamp && DateTime.to_unix(note.fm_timestamp),
      fm_created: note.fm_created && DateTime.to_unix(note.fm_created)
    }
  end

  # Encodes a Phase B HMAC binary as base64 for JSON-safe Qdrant payload.
  # Returns nil for nil — leaves the field absent so legacy/un-backfilled
  # rows don't poison filters with a fake hmac.
  defp encode_hmac(nil), do: nil
  defp encode_hmac(bin) when is_binary(bin), do: Base.encode64(bin)

  defp detect_language(text), do: Engram.KeywordIndex.LangDetect.detect(text)
end
