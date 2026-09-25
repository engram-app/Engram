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
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Vector.Qdrant

  require Logger

  @default_dims 1024

  # Chunked against Postgres' 65,535 bind-parameter cap — one bind per id in
  # `in ^batch`. A whole vault, or a sweep's candidate set, can exceed that in a
  # single statement.
  @id_query_batch 5_000

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
    with {:ok, count, _embedded_bytes, _dense?} <- index_note_with_usage(note, vault, user, []),
         do: {:ok, count}
  end

  @doc """
  `index_note/3`, plus the bytes this pass actually sent to the embedder
  (#1618). Chunk reuse makes that a small part of most edits, and a
  sparse-only pass sends nothing. Returns
  `{:ok, chunk_count, embedded_bytes, dense?}`, where `dense?` says whether
  the pass wrote dense vectors.

  Options:
    * `:dense` (default `true`) — `false` builds the sparse (BM25) leg only and
      never calls the embedder.
    * `:reserve_tokens` — `fn tokens -> boolean end`, called with the tokens
      this pass would actually send to the embedder, AFTER chunk reuse is
      planned (so a one-section edit asks for one section, not the note).
      `false` downgrades the pass to sparse-only, so the note stays
      keyword-searchable. `EmbedNote` passes the lifetime embed budget here.
    * `:release_tokens` — `fn tokens -> any end`, called when the embed call
      fails after a reservation, so a failed attempt is not charged.
  """
  def index_note_with_usage(note, %Engram.Vaults.Vault{} = vault, user \\ nil, opts \\ []) do
    # Resolve identity ONCE for the whole call. This function and
    # prepare_index/3 below both need the same `%User{}`, and both used to
    # fetch it independently — on the embed path that made four `get_user!`
    # round trips for one note (here, prepare_index, and twice more in
    # EmbedNote). Measured 2.1 users/job in prod on 2026-08-28. The argument is
    # optional so the six test modules and any future caller can keep passing
    # two args; the hot path passes the user it already has.
    #
    # `_with_subscription`: everything downstream asks about a limit —
    # `IndexCap.within_cap?/2` resolves the tier — and on a bare `get_user!/1` struct that is one `subscriptions`
    # query. The join folds it into this fetch. See #1502.
    user = user || Engram.Accounts.get_user_with_subscription!(note.user_id)

    case prepare_index(note, vault, user, opts) do
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
              {:ok, 0, 0, false}
            end

          {:error, :no_dek} = err ->
            emit_no_dek_telemetry(note)
            err
        end

      {:ok, prepared} ->
        with {:ok, count} <- commit_index(prepared),
             do: {:ok, count, prepared.embedded_bytes, prepared.dense?}

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
  def prepare_index(note, %Engram.Vaults.Vault{} = vault, user \\ nil, opts \\ []) do
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

        # A sparse-only pass (`dense: false`, or the embed budget refused the
        # reservation) never calls Voyage. `nil` vectors flow through
        # build_prepared/8, which emits a sparse-only named vector — the BM25
        # leg is computed locally from the chunk text, so keyword search works
        # with zero embedding spend.
        with :ok <- Qdrant.ensure_collection(collection(), dims),
             {:ok, filter_key} <- Crypto.dek_filter_key(user),
             {:ok, content_key} <- Crypto.dek_content_hash_key(user),
             {dense?, plan} =
               plan_within_budget(
                 note,
                 chunks,
                 content_key,
                 Keyword.get(opts, :dense, true),
                 opts
               ),
             texts = embed_texts(plan),
             {:ok, vectors} <- embed_or_release(dense?, texts, opts),
             :ok <- ensure_one_vector_per_text(vectors, texts, note),
             avgdl = Engram.KeywordIndex.Stats.avgdl(note.user_id, note.vault_id),
             {:ok, prepared} <-
               build_prepared(note, user, vault, plan, vectors, filter_key, avgdl, link_rows) do
          # What the embedder was actually sent (#1618): reused chunks and
          # sparse-only passes cost nothing, so the meter must not bill them.
          embedded_bytes = if dense?, do: text_bytes(texts), else: 0

          {:ok, prepared |> Map.put(:embedded_bytes, embedded_bytes) |> Map.put(:dense?, dense?)}
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
    # Tenant-scoped: `chunks` carries FORCE ROW LEVEL SECURITY, so unscoped this
    # gate reads false for a note that HAS chunks, `delete_note_index/1` is
    # skipped, and the previous pass's points survive the re-index as stale
    # duplicates. Scoping only the gate, deliberately: `delete_note_index/1`
    # opens its own scope and makes a Qdrant call, which must not run inside a
    # transaction.
    {:ok, has_chunks?} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.exists?(from(c in Chunk, where: c.note_id == ^note.id))
      end)

    if has_chunks? do
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

  Tenant context is handled internally: the chunk rewrite below and
  `Links.replace_links/4` each open their own `Repo.with_tenant/2`, so this is
  safe to call with or without an enclosing tenant (`with_tenant/2` is
  re-entrant for the same tenant, so a scoped caller pays nothing).

  This used to read "non-tenant-scoped callers run as the superuser role and
  bypass RLS". That was true of every environment and true of nothing in this
  code: under any role without SUPERUSER or BYPASSRLS the chunk insert raises
  42501. Scoping each write removes the dependency on how the app happens to
  connect.

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
      # Wholesale rewrite rather than a row-level diff: the rows are local and
      # cheap, and replacing them all sidesteps every ordering problem with
      # `chunks_note_id_position_index` when positions shift. One transaction
      # so OrphanSweep can never scroll a live point during the window where
      # its row is momentarily absent.
      #
      # `with_tenant` rather than a bare `Repo.transaction`: `chunks` carries
      # FORCE ROW LEVEL SECURITY with a `WITH CHECK` on
      # `current_setting('app.current_tenant', true)`, and `skip_tenant_check`
      # suppresses only Engram's own `prepare_query/3` guard — it sets nothing
      # in Postgres. Unscoped, the INSERT raises 42501 and the DELETE silently
      # matches zero rows. It has never bitten because every environment
      # connects as a superuser, which bypasses RLS even when FORCED; that is
      # an accident of deployment, not a property of this code.
      #
      # `with_tenant/2` opens the transaction itself and is re-entrant for the
      # same tenant, so a tenant-scoped caller pays nothing and the atomicity
      # the comment above depends on is unchanged.
      {:ok, _} =
        Repo.with_tenant(note.user_id, fn ->
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
      forget_chunk_reuse(note)
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
    # Tenant-scoped: same filtered-UPDATE class as `forget_chunk_reuse/1`. The
    # tenant is the argument, so there is nothing to discover.
    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        Repo.update_all(
          from(c in Chunk, where: c.user_id == ^user_id and not is_nil(c.context_hmac)),
          set: [context_hmac: nil]
        )
      end)

    :ok
  end

  @doc """
  Flags `note_ids` so their next index rebuilds every chunk from scratch.

  Two clears, in this order, and both are load-bearing:

    * `chunks.context_hmac` — chunk reuse (#1595) matches on it, so a surviving
      marker makes the "rebuild" reuse the very points it meant to replace. The
      reuse branch of `build_entry/3` does no embed, no tokenizer pass and no
      encryption, and discards the `avgdl` it is handed, so a stale BM25 weight
      and `token_count` would survive verbatim (#1477).
    * `notes.embed_hash` / `dense_indexed_hash` — `EmbedNote` skips a note whose
      `embed_hash` still equals its `content_hash`, which is every
      already-indexed note (#1607).

  Clearing only one of the two is a silent no-op, which is why this is one
  function rather than a step each caller remembers.

  Markers first: a failure between the two leaves a note that is still skipped
  but whose points are still named by its rows, so nothing becomes
  unsearchable. The reverse order strands a note that skips while naming points
  meant to be rebuilt.

  Callers must scope `note_ids` themselves — this applies to exactly the ids it
  is given.

  Callers must ALSO already be inside `Repo.with_tenant/2`. The two writes run
  under `Repo.cross_tenant/1`, which suppresses only Engram's application-level
  tripwire and sets no Postgres session state, so where RLS is enforced both
  `update_all`s are FILTERED by the policy — they report rows affected of zero
  and no error, and this function returns 0 having cleared nothing. An earlier
  version of this docstring said "with RLS bypassed", which is exactly
  backwards: `cross_tenant/1` bypasses the guard, not the policy.

  Returns the number of `notes` rows updated.

  The `repo` argument exists because the two callers need opposite pools, and
  getting it wrong is silent in the dangerous direction.

    * `ReindexKeyword` calls this INSIDE `Repo.with_tenant!/2`, so it must stay
      on `Engram.Repo` — the tenant scope is the point there.
    * `OrphanSweep` calls it with note_ids spanning every tenant by
      construction, so no `with_tenant` is possible. It must pass
      `Repo.maintenance()`.

  Both writes below are `update_all` against tables carrying FORCE ROW LEVEL
  SECURITY. An `update_all` the policy filters does not raise: it reports
  `{0, nil}` and the caller logs success having changed nothing. `cross_tenant/1`
  does NOT prevent that — it only suppresses the app-level `prepare_query/3`
  tripwire and sets no Postgres session state. See engram-app/Engram#1746.
  """
  @spec flag_notes_for_rebuild([Ecto.UUID.t()], module()) :: non_neg_integer()
  def flag_notes_for_rebuild(note_ids, repo \\ Repo)

  def flag_notes_for_rebuild([], _repo), do: 0

  def flag_notes_for_rebuild(note_ids, repo) do
    note_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@id_query_batch)
    |> Enum.reduce(0, fn batch, acc ->
      # One block over both writes, rather than the option on each: they are a
      # single ordered unit (markers before hashes, per the moduledoc above),
      # and the ordering only means anything if both run under the same intent.
      #
      # The wrapper stays on `Engram.Repo` whichever pool `repo` is: the flag is
      # process-local and `Engram.Repo.Maintenance` has no `prepare_query/3` to
      # suppress, so it is a no-op there and load-bearing here.
      Repo.cross_tenant(fn ->
        # `not is_nil` keeps a re-run from rewriting rows that are already NULL
        # — dead tuples and WAL for no change.
        _ =
          Chunk
          |> where([c], c.note_id in ^batch and not is_nil(c.context_hmac))
          |> repo.update_all(set: [context_hmac: nil])

        {n, _} =
          Note
          |> where([n], n.id in ^batch)
          |> repo.update_all(set: [embed_hash: nil, dense_indexed_hash: nil])

        acc + n
      end)
    end)
  end

  # Clears the reuse fingerprints for a note, forcing its next index to rebuild
  # every chunk. `nil` is the same "cannot be matched" state a row written
  # before the column existed is in.
  # Takes the note rather than an id because it needs the tenant. `chunks`
  # carries FORCE ROW LEVEL SECURITY and an UPDATE is FILTERED by the policy
  # rather than rejected, so unscoped this clears NOTHING and still returns
  # `:ok` — which breaks the invariant in the moduledoc above in the silent
  # direction: the Qdrant points are already gone, the markers survive, and the
  # next index reuses point ids that no longer exist.
  defp forget_chunk_reuse(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(
          from(c in Chunk, where: c.note_id == ^note.id and not is_nil(c.context_hmac)),
          set: [context_hmac: nil]
        )
      end)

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
      # Tenant-scoped: a DELETE is FILTERED by the policy rather than rejected,
      # so unscoped this removes nothing and reports success, leaving orphan
      # chunk rows naming points that are already gone from Qdrant.
      #
      # `note` may be a synthetic map here, not a Note struct (see
      # `Engram.Workers.DeleteNoteIndex.perform/1`) — it carries `:user_id`,
      # which is all this needs.
      {:ok, _} =
        Repo.with_tenant(note.user_id, fn ->
          Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id))
        end)

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
    with :ok <- delete_points_for_note(note) do
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
  # Takes the note rather than an id because it needs the tenant. Unscoped this
  # read is filtered to [], so the by-id delete silently removes nothing and
  # the whole point of running it before the rows are dropped is lost — the
  # hmac filter below is only the belt, and it misses points whose note has
  # since been re-pathed.
  #
  # Only the READ is scoped; the Qdrant call stays outside, so no transaction
  # is held across a network round trip.
  defp delete_points_for_note(note) do
    {:ok, point_ids} =
      Repo.with_tenant(note.user_id, fn ->
        Chunk
        |> where([c], c.note_id == ^note.id)
        |> select([c], c.qdrant_point_id)
        |> Repo.all()
      end)

    point_ids
    |> Enum.reject(&is_nil/1)
    |> then(&Qdrant.delete_points(collection(), &1))
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp doc_embed_model, do: Application.get_env(:engram, :doc_embed_model)

  # `do_embed_batch/1` passes `:doc_embed_model` only when it is set, and the
  # embedder falls back to `:embed_model` otherwise. The reuse fingerprint has
  # to name the model actually used, or changing EMBED_MODEL with
  # DOC_EMBED_MODEL unset leaves every hmac identical and the collection
  # silently mixes two models' embedding spaces (#1606).
  defp effective_embed_model, do: doc_embed_model() || Application.get_env(:engram, :embed_model)

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
  # byte ceiling bounds the token sum for any content and any tokenizer.
  #
  # 118KB rather than a flush 120KB because `tokens <= bytes` covers tokens
  # DERIVED from content, not ones the tokenizer INSERTS: BERT-family models add
  # ~2 per input ([CLS]/[SEP]), which at 128 inputs is 120,256 — over the line
  # by a hair that only opens at 1.0 bytes/token. Prod's worst measured is 1.39,
  # so this is margin against a case we have never seen rather than one we have.
  # It costs nothing to be actually correct instead of nearly correct.
  #
  # The ceiling only binds because `Markdown.enforce_size_cap/1` bounds
  # `context_text` — text AND prefix. Do not weaken that to a `text`-only cap:
  # `batch_texts/1` lets a single over-budget input through alone, so one
  # unbounded `context_text` bypasses this ceiling entirely.
  #
  # Cost is requests, not money — Voyage bills tokens. But they are not free:
  # the byte cap now closes a batch whenever the average chunk exceeds ~937
  # bytes (120,000/128), which is ordinary prose, not just the base64 case
  # above; under 200KB that threshold was ~1,562. Prod runs `VOYAGE_RPM=1600`
  # through the client-side throttle in `Embedders.Voyage.throttle_check/1`,
  # which synthesizes a 429 that `EmbedNote` answers with a 60s snooze
  # (`EMBED_429_SNOOZE_SECONDS`). So a bulk import trades wall-clock for
  # correctness here. That is the right trade against a permanent poison loop,
  # and the RPM is the knob if it ever bites.
  @embed_batch_size 128
  @embed_batch_bytes 118_000

  # Plans a dense pass, then asks the caller's budget for exactly what that
  # pass would send (reused chunks cost nothing). Refused → re-plan sparse:
  # the fingerprints differ, so a dense plan cannot be reused for a sparse pass.
  defp plan_within_budget(note, chunks, content_key, false, _opts),
    do: {false, plan_chunks(note, chunks, content_key, false)}

  defp plan_within_budget(note, chunks, content_key, true, opts) do
    plan = plan_chunks(note, chunks, content_key, true)
    reserve = Keyword.get(opts, :reserve_tokens, fn _tokens -> true end)

    case plan |> embed_texts() |> text_bytes() |> UsageMeters.estimate_tokens() do
      0 ->
        {true, plan}

      tokens ->
        if reserve.(tokens),
          do: {true, plan},
          else: {false, plan_chunks(note, chunks, content_key, false)}
    end
  end

  # Anything but a successful embed gives its reservation back, exactly once:
  # an `{:error, _}`, a raise, a throw or an exit. The `catch` re-raises with
  # the original stacktrace, so callers see the same failure. A failure AFTER
  # the embed (the Qdrant commit) keeps the charge: Voyage billed those tokens.
  #
  # Not covered: a hard node kill (or a brutal kill of the job process, e.g. an
  # Oban timeout) between the reservation and the embed returning — no code
  # runs, so that pass's tokens stay charged. Accepted: rare, and bounded to one
  # note's worth of tokens per kill.
  defp embed_or_release(false, texts, _opts), do: maybe_embed(false, texts)

  defp embed_or_release(true, texts, opts) do
    release = fn ->
      _ =
        Keyword.get(opts, :release_tokens, fn _tokens -> :ok end).(
          texts
          |> text_bytes()
          |> UsageMeters.estimate_tokens()
        )
    end

    result =
      try do
        maybe_embed(true, texts)
      catch
        kind, reason ->
          release.()
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    with {:error, _} <- result, do: release.()
    result
  end

  defp text_bytes(texts), do: texts |> Enum.map(&byte_size/1) |> Enum.sum()

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
  # text wider than the byte budget still goes out alone rather than looping,
  # because dropping it would silently unindex the content.
  #
  # That escape hatch is a REAL hole, not a formality, and the only thing
  # closing it is `Markdown.enforce_size_cap/1` bounding `context_text` to
  # ~2.5KB. An earlier version of this comment claimed "the chunker caps it long
  # before here" while the chunker capped only `text` — so a 200KB heading
  # prefix rode straight past this ceiling, one oversized batch per chunk. If
  # that cap ever loosens, this line stops being a safety valve and becomes the
  # bypass.
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
  defp plan_chunks(note, chunks, content_key, dense?) do
    chunks =
      Enum.map(chunks, fn chunk ->
        Map.put(chunk, :context_hmac, fingerprint(content_key, chunk.context_text, dense?))
      end)

    # Tenant-scoped: unscoped this read is filtered to [], so reuse never
    # matches. That is not a correctness break but a cost one — every index
    # pays a full re-embed, and the prior pass's points are left orphaned in
    # Qdrant rather than being reused or replaced.
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Chunk
        |> where([c], c.note_id == ^note.id)
        |> select([c], {c.context_hmac, c.qdrant_point_id, c.token_count})
        |> Repo.all()
      end)

    existing = Enum.reject(rows, fn {_hmac, point_id, _tokens} -> is_nil(point_id) end)

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

  # What a point HOLDS is part of the fingerprint, not just its text (#1606).
  # A sparse-only point has no dense vector: matching it on a dense pass
  # stamped the note densely indexed with nothing behind the stamp, and a
  # sparse-only pass kept vectors it had decided not to pay for. The model is in it for
  # the same reason, since another model's vector is not reusable either.
  defp fingerprint(content_key, context_text, true) do
    Crypto.hmac_content_hash(content_key, "dense:#{effective_embed_model()}\n" <> context_text)
  end

  defp fingerprint(content_key, context_text, false) do
    Crypto.hmac_content_hash(content_key, "sparse\n" <> context_text)
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
