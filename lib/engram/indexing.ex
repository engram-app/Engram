defmodule Engram.Indexing do
  @moduledoc """
  Orchestrates the parse → embed → upsert pipeline.

  Called from EmbedNote worker (async, after note upsert).
  Uses the configured embedder adapter and Qdrant client.
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.EmbedModels
  alias Engram.Indexing.PayloadV5
  alias Engram.Indexing.PointId
  alias Engram.Indexing.RetainedVectors
  alias Engram.Indexing.VectorCache
  alias Engram.KeywordIndex
  alias Engram.Logger.Metadata
  alias Engram.Notes.Chunk
  alias Engram.Notes.ChunkPoint
  alias Engram.Notes.FieldCatalog
  alias Engram.Notes.FlatFields
  alias Engram.Notes.Frontmatter
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.Note
  alias Engram.Notes.NoteAttr
  alias Engram.Notes.OkfFields
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild
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
    * `:in_commit` — `fn chunk_count, dense?, index_tier -> any end`, run on
      success INSIDE the tenant transaction that writes the chunk rows (or, on
      the no-chunks path, in one opened after the purge). `EmbedNote` stamps its
      hashes here, so the stamp shares the index write's transaction instead
      of opening its own. `index_tier` is the tier this pass used: `floor_tier/2`,
      or a floor tier when a full pass would overrun `points_budget_ok?/3`.
    * `:keep_dense`: a maintenance pass. If the plan would floor a note
      that has dense vectors now (over a budget, not a forced floor), return
      `{:error, :over_budget}` and leave its index as it is.
    * `:index_tier`: overrides the note's own `index_tier` (see
      `floor_tier/2`). `"floor"` / `"floor_paid"` take the floor path
      (`floor_plan/2`); an explicit `nil` asks for a full pass, which still
      floors if it would overrun `points_budget_ok?/3`. Either way the
      note row ends up stamped with the tier the pass used.
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
    # `_with_subscription`: everything downstream asks about a limit (the
    # embed budget resolves the tier), and on a bare `get_user!/1` struct that
    # is one `subscriptions` query. The join folds it into this fetch. See #1502.
    user = user || Engram.Accounts.get_user_with_subscription!(note.user_id)

    # One re-resolve when the reaper deleted a key id mid-pass
    # (`hold_key_ids!/2`); the retained vectors make the retry Voyage-free.
    with_pass_model(user, opts, fn ->
      case index_once(note, vault, user, opts) do
        {:error, :frontmatter_keys_gone} -> index_once(note, vault, user, opts)
        other -> other
      end
    end)
  end

  @pass_model_key {__MODULE__, :pass_model}

  # The doc model of this pass, by the owner's plan (`Engram.EmbedModels`):
  # `opts[:doc_model]` (EmbedNote stamps the same one) or resolved here.
  # Held in the process for the pass, so every reuse key (retained vectors,
  # vector cache, fingerprints) and the Voyage request name the same model.
  # Off per-plan nothing is set and `embed_model/0` applies, as before.
  defp with_pass_model(user, opts, fun) do
    if EmbedModels.per_plan?() do
      prev = Process.put(@pass_model_key, opts[:doc_model] || EmbedModels.doc_model(user))

      try do
        fun.()
      after
        if prev, do: Process.put(@pass_model_key, prev), else: Process.delete(@pass_model_key)
      end
    else
      fun.()
    end
  end

  # The model this pass embeds with: the plan's, else the build's.
  defp pass_model, do: Process.get(@pass_model_key) || embed_model()

  defp index_once(note, vault, user, opts) do
    case prepare_index(note, vault, user, opts) do
      {:ok, :no_chunks} ->
        case Crypto.get_dek(user) do
          {:ok, _dek} ->
            # `:no_chunks` means this note must end up with ZERO index
            # artifacts: the note was emptied, so the PREVIOUS artifacts must
            # go, or stale content stays searchable.
            #
            # Errors PROPAGATE. Swallowing a failed Qdrant delete here would
            # let the caller stamp `embed_hash` and never revisit the note, so
            # the points it failed to remove would stay searchable forever.
            # Returning the error costs one Oban retry.
            #
            # No `note_links` write here or in commit_index/1: ExtractNoteLinks
            # owns them (see its moduledoc), reading the authoritative CRDT
            # content rather than this facade.
            #
            # The 4th element says whether the dense leg is complete. A note
            # with nothing to index (empty, or only base64 blobs) has all of
            # the dense vectors it ever will, so `true`: leaving it `false`
            # keeps `dense_indexed_hash` nil and ReconcileEmbeddings re-selects
            # it every tick.
            #
            # An emptied note has no floor point either, so its tier clears.
            with :ok <- purge_stale_index(note) do
              Repo.with_tenant!(note.user_id, fn ->
                {_, _} =
                  Repo.update_all(
                    from(n in Note,
                      where:
                        n.id == ^note.id and n.kind == "note" and
                          (not is_nil(n.index_tier) or not is_nil(n.chunk_count))
                    ),
                    set: [index_tier: nil, chunk_count: nil]
                  )

                run_in_commit(note, opts, 0, true, nil)
              end)

              {:ok, 0, 0, true}
            end

          {:error, :no_dek} = err ->
            emit_no_dek_telemetry(note)
            err
        end

      {:ok, prepared} ->
        # Retained BEFORE the commit, not on a refusal: any failure after the
        # embed (Qdrant backpressure, a Qdrant error, a raise in the chunk
        # write) must not make the retry pay Voyage and the meter again.
        # 2026-10-19: a 7,304-chunk note crashed the row insert 5 times and
        # each attempt re-embedded the whole note (3-4 full paid passes).
        retain(prepared.retain)

        case commit_index(
               prepared,
               &run_in_commit(note, opts, &1, prepared.dense?, prepared.index_tier)
             ) do
          {:ok, count} ->
            forget_retained(prepared.retain)
            {:ok, count, prepared.embedded_bytes, prepared.dense?}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Phase 1 of the indexing pipeline. Parses the note, calls the embedder, and
  builds the encrypted Qdrant payloads + chunk row inserts in memory.

  Writes no index rows. Its one DB write (v5 format on) is the frontmatter
  key dictionary (`FrontmatterKeys.resolve/3`), committed in its own short
  transaction, so this must NOT run inside a caller's transaction: the
  dictionary's advisory lock would then be held across the slow Voyage AI
  HTTP call, which is meant to run outside any Postgres connection.

  Returns:
    * `{:ok, :no_chunks}` — note has no parseable chunks; caller must still
      purge the previous index
    * `{:ok, prepared}` — ready to hand to `commit_index/1`
    * `{:error, reason}` — embed failed, encryption failed, etc.
  """
  def prepare_index(note, %Engram.Vaults.Vault{} = _vault, user \\ nil, opts \\ []) do
    chunks = Markdown.parse(note.content || "", note.path)
    {note, okf_healed?} = heal_okf_timestamp(note)

    # An empty note needs no identity at all, so that branch stays ahead of the
    # fetch. Everything past it does: the embed below wants the `%User{}`,
    # and resolving it once here is what keeps this path at one `users` query
    # per note. See #1502.
    if chunks == [] do
      {:ok, :no_chunks}
    else
      user = user || Engram.Accounts.get_user_with_subscription!(note.user_id)
      prepare_chunks(note, user, chunks, opts, okf_healed?)
    end
  end

  defp prepare_chunks(note, user, chunks, opts, okf_healed? \\ false) do
    dims = Application.get_env(:engram, :embed_dims, @default_dims)
    # Counted up front so nothing after planning holds the raw chunks: on a
    # merged note the plan has its own copies (Task 9.2).
    n = length(chunks)

    # A sparse-only pass (`dense: false`, or the embed budget refused the
    # reservation) never calls Voyage. `nil` vectors flow through
    # build_prepared/8, which emits a sparse-only named vector: the BM25
    # leg is computed locally from the chunk text, so keyword search works
    # with zero embedding spend. A floor pass is sparse-only too, and asks no
    # budget at all: it is maintenance, never metered.
    #
    # The points-budget count and the plan's chunk read share ONE tenant
    # transaction (both `with_tenant` calls nest into it), so the check costs
    # a query, not a transaction. ponytail: the token reservation's one-row
    # upsert runs inside it too and locks the meter row even when it refuses.
    # Nothing after it queries but a refusal's meter read for its log line;
    # the sparse re-plan reuses the rows already read (`plan_within_budget/5`).
    # Move the reservation past the commit if that ever contends.
    with :ok <- Qdrant.ensure_collection(collection(), dims),
         {:ok, filter_key} <- Crypto.dek_filter_key(user),
         {:ok, content_key} <- Crypto.dek_content_hash_key(user),
         {:ok, opts} <- with_vector_cache(user, note, content_key, dims, opts),
         {tier, dense?, plan, retained} <-
           Repo.with_tenant!(note.user_id, fn ->
             with :ok <- tier_unchanged(note),
                  do: plan_index(note, user, chunks, content_key, opts)
           end),
         {:ok, dense?, plan, retained} <-
           rebuild_sources(note, dense?, plan, retained, content_key, opts),
         :ok = collect_garbage(n),
         texts = embed_texts(plan),
         {:ok, vectors} <- paid_once(note, retained, dense?, plan, texts, opts),
         :ok <- ensure_one_vector_per_text(vectors, texts, note),
         :ok = collect_garbage(n),
         avgdl = avgdl(note.user_id, note.vault_id),
         {:ok, prepared} <-
           build_prepared(note, user, plan, vectors, filter_key, avgdl) do
      # What the embedder was actually sent (#1618): reused chunks and
      # sparse-only passes cost nothing, so the meter must not bill them.
      # Retained vectors were paid for by the attempt that kept them.
      # With the vector cache on, only its misses were sent (`:embed_bytes`).
      embedded_bytes =
        if dense? and is_nil(retained),
          do: Map.get_lazy(plan, :embed_bytes, fn -> text_bytes(texts) end),
          else: 0

      # A note holding fewer points than its chunks (floored or merged)
      # records how many a full pass would write: the index budget sweep
      # promotes from it.
      chunk_count = if tier != nil or merged?(plan), do: n

      {:ok,
       Map.merge(prepared, %{
         embedded_bytes: embedded_bytes,
         dense?: dense?,
         index_tier: tier,
         okf_healed?: okf_healed?,
         write_first: regroup?(note, plan),
         retain: if(dense? and texts != [], do: {retained_key(note, texts), vectors}),
         chunk_count: chunk_count
       })}
    else
      {:error, :no_dek} = err ->
        emit_no_dek_telemetry(note)
        err

      other ->
        other
    end
  end

  # OKF v0.2 `generated.at` is read since #2066, but `fm_timestamp` is set
  # on write, so a note saved before then holds nil until edited. Re-derived
  # here, so its next index (the v5 rebuild reaches every note) heals the
  # payload (the payload hash moves, so reused points are refreshed) and the
  # row (`stamp_okf_timestamp/1`). Only a nil timestamp next to a `generated`
  # key pays the YAML parse; every other note costs a substring check.
  defp heal_okf_timestamp(%{fm_timestamp: nil, content: content} = note)
       when is_binary(content) do
    with {block, _body} when is_binary(block) <- Frontmatter.split(content),
         true <- String.contains?(block, "generated"),
         %{fm_timestamp: %DateTime{} = ts} <- OkfFields.from_parse(Frontmatter.parse(block)) do
      {%{note | fm_timestamp: ts}, true}
    else
      _ -> {note, false}
    end
  end

  defp heal_okf_timestamp(note), do: {note, false}

  # Inside the chunk-row transaction; guarded on the content it was derived
  # from and on the column still being nil, so an edit in between wins.
  defp stamp_okf_timestamp(%{okf_healed?: true, note: note}) do
    {_, _} =
      Repo.update_all(
        from(n in Note,
          where:
            n.kind == "note" and n.id == ^note.id and n.content_hash == ^note.content_hash and
              is_nil(n.fm_timestamp)
        ),
        set: [fm_timestamp: note.fm_timestamp]
      )

    :ok
  end

  defp stamp_okf_timestamp(_prepared), do: :ok

  @floor_tiers ["floor", "floor_paid"]

  # A pass that changes how the note is grouped writes before it deletes,
  # and with the budget on every pass does (review L1): purging by path
  # filter first let a stale pass, about to roll back as superseded, wipe
  # the newer edit's points. Deleting only after the locked content check
  # commits closes that. Off, passes keep their pre-budget order.
  defp regroup?(note, plan),
    do:
      budget_enabled?() or merged?(plan) or Map.get(note, :index_tier) != nil or
        Map.get(note, :chunk_count) != nil or Map.get(plan, :rebuild?, false)

  defp merged?(plan), do: Enum.any?(plan.entries, &Map.get(entry_chunk(&1), :merged, false))

  # The index budget sweep may have demoted or promoted the note since it was
  # loaded. Checked inside the planning transaction, before any Voyage call
  # or Qdrant write, so a lost race spends nothing; `stamp_index_tier/3`
  # re-checks at commit.
  defp tier_unchanged(note) do
    expected = Map.get(note, :index_tier)

    case Repo.one(
           from(n in Note, where: n.id == ^note.id and n.kind == "note", select: {n.index_tier})
         ) do
      {tier} when tier != expected -> {:error, :index_tier_changed}
      _ -> :ok
    end
  end

  # `chunks.position` is a smallint.
  @max_positions 32_767

  @doc """
  Chunks a note can store: past #{@max_positions} (`chunks.position` is a
  smallint) they merge to fit, budget or not. A 30 MB self-host note of tiny
  sections crashed its row insert on every attempt (CI huge-notes). Under
  the limit the list comes back unchanged.
  """
  @spec fit_positions([map()], boolean()) :: [map()]
  def fit_positions(chunks, merged?) when length(chunks) > @max_positions,
    do: cap_chunks(chunks, @max_positions, merged?)

  def fit_positions(chunks, _merged?), do: chunks

  defp merged_rows?(rows), do: Enum.any?(rows, &(elem(&1, 3) != nil))

  @doc """
  Whether the v5 index budget is on: the per-note cap merge, the index
  points budget and its floor, the per-pass embed budget, and the 04:00
  UTC recap and budget sweeps (`ReconcileEmbeddings`). Off by default
  (review H2): the caps are sized for chunker v5 (~5.2 points a note), so
  on v3-chunked data they would demote and re-embed notes the v5 pass
  re-embeds anyway. `INDEX_BUDGET_ENABLED=true` turns it on as a step of
  the v5 go sequence, after the pass and with the v5 stamp. Off, a pass
  plans exactly as before the budget existed.
  """
  @spec budget_enabled?() :: boolean()
  def budget_enabled?, do: Application.get_env(:engram, :index_budget_enabled, false)

  # The per-note cap runs first, so the points budget below counts the points
  # a full pass would actually write.
  defp plan_index(note, user, chunks, content_key, opts) do
    if budget_enabled?() or floor_tier(note, opts),
      do: plan_budgeted(note, user, chunks, content_key, opts),
      else: plan_unbudgeted(note, chunks, content_key, opts)
  end

  # The pre-budget plan: one point a chunk, metered in full.
  defp plan_unbudgeted(note, chunks, content_key, opts) do
    rows = indexed_rows(note)

    {dense?, plan, retained} =
      plan_within_budget(
        note,
        rows,
        fit_positions(chunks, merged_rows?(rows)),
        content_key,
        Keyword.get(opts, :dense, true),
        opts
      )

    {nil, dense?, plan, retained}
  end

  defp plan_budgeted(note, user, chunks, content_key, opts) do
    forced = floor_tier(note, opts)
    cap = note_points_cap(user)
    rows = if forced, do: [], else: indexed_rows(note)

    capped =
      if forced,
        do: chunks,
        else:
          chunks
          |> cap_chunks(cap, merged_rows?(rows))
          |> fit_positions(merged_rows?(rows))
          |> within_pass_embed_budget(opts)

    case forced || over_note_cap_tier(note, capped, cap) ||
           over_points_budget_tier(note, user, capped) do
      nil ->
        dense_opt = Keyword.get(opts, :dense, true)

        {dense?, plan, retained} =
          plan_within_budget(note, rows, capped, content_key, dense_opt, opts)

        {nil, dense?, plan, retained}

      tier ->
        if !forced and Keyword.get(opts, :keep_dense, false) and dense_now?(note),
          do: {:error, :over_budget},
          else: {tier, false, floor_plan(note, chunks), nil}
    end
  end

  # Review M2: a maintenance pass (`keep_dense: true`, a version rebuild or a
  # recap) over budget keeps a note's dense points instead of flooring it:
  # the floor deletes vectors a later promotion pays to rebuild. The note
  # keeps its old index; the budget sweep decides demotions.
  defp dense_now?(note) do
    dense = Map.get(note, :dense_indexed_hash)
    dense != nil and dense == Map.get(note, :embed_hash)
  end

  # Dense bytes one pass may send Voyage (chunker v5 Task 9.2). The pass must
  # finish inside EmbedNote's 10 minute timeout, or Oban kills it after it
  # paid and every retry pays again. 12 MiB is ~107 requests of 118 KB: at
  # the slowest measured ~3 s a full batch that is ~5.3 min, which leaves
  # the rest for the local work (bounded at 6 s/MB, 3 min at 30 MB). At
  # Voyage's 3M TPM a pass is >= ~1.4 min even for CJK at a token a char.
  #
  # Only a note over ~12 MB of prose reaches it: a paid 30 MB note (1,024
  # groups x 30 KB) or a self-host one. Prose past the budget is indexed
  # keyword-only, in note order, so the dense part is the note's first 12
  # MiB of prose and is the same on every pass: unchanged content reuses its
  # points, nothing flaps, and no word leaves the keyword leg. Free cannot
  # reach it (128 x 30 KB is ~3.8 MB). ponytail: a prefix, not a spread;
  # split the embed across jobs (needs the per-batch vector cache, PR-12) to
  # cover the rest densely.
  @max_pass_embed_bytes 12 * 1024 * 1024

  defp max_pass_embed_bytes,
    do: Application.get_env(:engram, :max_pass_embed_bytes, @max_pass_embed_bytes)

  # With the vector cache on the budget binds on cache MISSES instead
  # (`with_cache_lookup/3`): a pass embeds up to the budget, caches it and
  # snoozes, and the next pass finds those as hits. So every prose byte goes
  # dense, over as many passes as it takes.
  defp within_pass_embed_budget(chunks, opts) do
    if Keyword.has_key?(opts, :vector_cache),
      do: chunks,
      else: within_pass_embed_budget(chunks)
  end

  defp within_pass_embed_budget(chunks) do
    budget = max_pass_embed_bytes()

    {chunks, _used} =
      Enum.map_reduce(chunks, 0, fn chunk, used ->
        if Markdown.dense_kind?(chunk.kind) do
          used = used + IO.iodata_length(chunk.embed_text)
          {if(used > budget, do: Map.put(chunk, :sparse_only, true), else: chunk), used}
        else
          {chunk, used}
        end
      end)

    chunks
  end

  # Decided BEFORE any token reservation, so a floored pass reserves nothing.
  # A full plan writes one point per chunk, reused or not.
  #
  # The note a pass indexes is the one the user is working on (review M1):
  # it may overshoot the cap by `@inline_overshoot_pct` rather than floor,
  # and the 04:00 sweep brings the account back under by demoting the
  # least recently edited notes. Past that it floors.
  @inline_overshoot_pct 5

  defp over_points_budget_tier(note, user, chunks) do
    unless points_budget_ok?(user, note.id, length(chunks), @inline_overshoot_pct),
      do: demoted_tier(note)
  end

  # ponytail: 7,500 estimated tokens (bytes / 4, as the reservation counts)
  # per merged point, so ~30 KB. At the densest content measured, 1.39
  # bytes/token, that is ~21,600 real tokens: under Voyage's 32,000 input
  # limit with room for the prefix. Not a density guess: even at one byte
  # per token 30 KB stays under 32,000. A group closes before it would pass
  # this, so a note only floors when it needs more than its cap of such
  # groups: over ~3.8 MB at a 128 cap. Raise the cap for that tier if real
  # notes ever do.
  @max_merged_tokens 7_500

  # Still over the cap after merging (every group at the ceiling), or a
  # single chunk over the ceiling: the note floors.
  defp over_note_cap_tier(note, chunks, cap) do
    if (is_integer(cap) and length(chunks) > cap) or
         Enum.any?(
           chunks,
           &(UsageMeters.estimate_tokens(IO.iodata_length(&1.embed_text)) > @max_merged_tokens)
         ),
       do: demoted_tier(note)
  end

  # "floor_paid" when the floor takes dense vectors away (the note's indexed
  # content has them) or the note already carries it, so its promotion is
  # never charged again; else "floor".
  defp demoted_tier(note) do
    dense = Map.get(note, :dense_indexed_hash)

    if Map.get(note, :index_tier) == "floor_paid" or
         (dense != nil and dense == Map.get(note, :embed_hash)),
       do: "floor_paid",
       else: "floor"
  end

  # nil: no cap (billing disabled, or a non-positive override).
  defp note_points_cap(user) do
    case Engram.Billing.effective_limit(user, :note_points_cap) do
      cap when is_integer(cap) and cap > 0 -> cap
      _ -> nil
    end
  end

  @doc """
  Merges ADJACENT chunks of the SAME kind so a note holds at most `cap`
  points, with content-defined group boundaries so an edit moves only the
  groups around it. A group never mixes kinds (chunker v5 Task 9.1): a data,
  frontmatter or drawing chunk never joins a prose group, so it never gets a
  dense vector, and a prose chunk never joins a keyword-only group, so it
  never loses one.

  Merges when `n > cap`, or when `merged?` (the note's stored points are
  already merged) and `n > 0.75 * cap`: hysteresis, so an edit moving `n`
  back and forth across the cap regroups the note once, not on every
  crossing. A note un-merges only at or below 0.75 x cap.

  `g` is the smallest power of two >= `1.25 * n / cap`, and at least 2,
  aiming at 0.4 to 0.8 x cap groups. A group closes after each chunk whose
  hash is `0 mod g`, before a chunk of another kind, or before a chunk that
  would take it past the merged-point ceiling. The hash is an UNKEYED
  SHA-256 of the chunk's `text` (C12): keyed on the DEK, a key rotation
  regrouped every capped note, and a regroup is a re-embed. A boundary says
  only that two adjacent chunks were cut apart, which leaks little. Powers of two nest (`0 mod 2g`
  implies `0 mod g`), so growth regroups the whole note only when `g`
  steps, i.e. when `n` doubles. More than `cap` groups doubles `g` and
  redoes it, up to `g >= n`; still over the cap there (the ceiling alone
  forces more groups) and the caller floors the note. Contiguous, in order,
  no text dropped. A group of one is its chunk unchanged (same fingerprint,
  so it reuses the unmerged point). Every other group is a merged chunk:

    * `text`: the members' `text` joined with "\n\n"
    * `context_text` / `embed_text`: its first member's prefix + that text,
      exactly what the chunker gives a single chunk with that text
    * `heading_path` and `headings`: nil. It spans sections, so its first
      member's heading would label a hit wrongly (review L5). Instead a
      member under other parents than the one before it opens with a
      breadcrumb line, `A > B` (its path without the title), as the
      chunker's min512 merge does
    * `kind`: "prose" if any member is, else its first member's
    * `char_start` of its first member to the largest `char_end` (a
      frontmatter chunk has `char_end` 0)
    * `token_count`: the members' `UsageMeters.estimate_tokens/1` sum
    * `merged: true`: its row stays out of `avgdl` and its keyword vector
      uses length `min(len, avgdl)`, as a floor point's does
    * `members`: the chunks it was merged from

  Positions are renumbered from 0. Not merging (or with a nil cap) the list
  comes back unchanged.
  """
  @spec cap_chunks([map()], pos_integer() | nil, boolean()) :: [map()]
  def cap_chunks(chunks, cap, merged? \\ false)

  def cap_chunks(chunks, cap, merged?) when is_integer(cap) and cap > 0 do
    n = length(chunks)

    if merges?(n, cap, merged?) do
      chunks
      |> hashed()
      |> content_groups(cap, pow2_at_least(max(2, div(5 * n + 4 * cap - 1, 4 * cap))), n)
      |> merge_groups()
    else
      chunks
    end
  end

  def cap_chunks(chunks, _cap, _merged?), do: chunks

  @doc """
  Whether a note of `n` chunks merges under a per-note `cap`, given whether
  its stored points are merged now. `ReconcileEmbeddings` unmerges a note
  (an upgrade, a raised override) only where this says false.
  """
  def merges?(n, cap, merged?), do: n > cap or (merged? and 4 * n > 3 * cap)

  # ponytail: `:crypto` over the text in place, not a new NIF: no copy, no
  # key, ~2 KB a chunk. 48 bits is plenty for `rem(hash, g)` with g <= 2n.
  defp hashed(chunks),
    do:
      Enum.map(
        chunks,
        &{&1, :binary.decode_unsigned(binary_part(:crypto.hash(:sha256, &1.text), 0, 6))}
      )

  defp merge_groups(groups),
    do:
      Enum.with_index(groups, fn members, position ->
        %{merge_group(members) | position: position}
      end)

  defp pow2_at_least(x, g \\ 1), do: if(g >= x, do: g, else: pow2_at_least(x, g * 2))

  # Past `g >= n` doubling cannot lower the count: what is left is forced by
  # the ceiling.
  defp content_groups(pairs, cap, g, n) do
    groups = close_groups(pairs, g)

    if length(groups) > cap and g < n,
      do: content_groups(pairs, cap, g * 2, n),
      else: groups
  end

  # The merged chunks a note's stored points were built from, whatever cap
  # built them: `m` points from `n` chunks can only come from a power-of-two
  # `g` whose groups number `m`. nil if none does (not a merged note).
  defp merged_like(chunks, m) do
    pairs = hashed(chunks)
    n = length(chunks)

    Stream.iterate(1, &(&1 * 2))
    |> Stream.take_while(&(&1 <= 2 * n))
    |> Stream.map(&close_groups(pairs, &1))
    |> Enum.find(&(length(&1) == m))
    |> case do
      nil -> nil
      groups -> merge_groups(groups)
    end
  end

  # Bytes of the members' `embed_text`s bound the merged one's from above
  # (each carries its own prefix plus "\n\n"), so a group that fits by this
  # sum fits the ceiling. Frontmatter never shares a group with the body:
  # `acc` is reversed, so its head is the group's last chunk. Other kinds do
  # share (review H1): closing on every kind change gave a note one group
  # per kind run, so 129 prose/table runs floored a 55 KB Free note.
  defp close_groups(pairs, g) do
    Enum.chunk_while(
      pairs,
      {[], 0},
      fn {chunk, hash}, {acc, bytes} ->
        size = byte_size(chunk.embed_text)

        {emit, acc, bytes} =
          if acc != [] and
               (frontmatter?(hd(acc)) != frontmatter?(chunk) or
                  UsageMeters.estimate_tokens(bytes + size) > @max_merged_tokens),
             do: {Enum.reverse(acc), [chunk], size},
             else: {nil, [chunk | acc], bytes + size}

        cond do
          rem(hash, g) == 0 and emit -> {:cont, [emit, Enum.reverse(acc)], {[], 0}}
          rem(hash, g) == 0 -> {:cont, [Enum.reverse(acc)], {[], 0}}
          emit -> {:cont, [emit], {acc, bytes}}
          true -> {:cont, {acc, bytes}}
        end
      end,
      fn
        {[], _} -> {:cont, []}
        {acc, _} -> {:cont, [Enum.reverse(acc)], {[], 0}}
      end
    )
    |> Enum.concat()
  end

  # Never a group member: frontmatter, and the chunks whose dense input is
  # not their text (property notes, canvas cards).
  defp frontmatter?(chunk), do: chunk.kind in ~w(frontmatter frontmatter_dense canvas_dense)

  defp merge_group([single]), do: single

  # A group is "prose" if any member is (then it is dense), else its first
  # member's kind. Its keyword input (`context_text`) and payload `text`
  # hold every member; its dense input (`embed_text`) only the prose ones,
  # so a table or a drawing inside a prose group never reaches Voyage.
  defp merge_group([first | _] = members) do
    members = with_crumbs(members)
    text = Enum.map_join(members, "\n\n", & &1.crumbed)
    prose? = Enum.any?(members, &(&1.kind == "prose"))

    embed =
      if prose?,
        do: members |> Enum.filter(&(&1.kind == "prose")) |> Enum.map_join("\n\n", & &1.crumbed),
        else: text

    # iodata, prefix + text: binaries, the two inputs were two more copies
    # of the merged text, ~2x the note on the job (Task 9.2). Each consumer
    # (fingerprint, keyword encode, Voyage batch) flattens one slice at a
    # time.
    Map.merge(first, %{
      kind: if(prose?, do: "prose", else: first.kind),
      heading_path: nil,
      headings: nil,
      # The sections it joins, so keyword scoring sees a merged point
      # (plan Task 14.1); a member may itself be a min512 chunk.
      section_count: members |> Enum.map(&Map.get(&1, :section_count, 1)) |> Enum.sum(),
      text: text,
      context_text: [prefix(first.context_text, first.text), text],
      embed_text: [prefix(first.embed_text, first.text), embed],
      char_end: members |> Enum.map(& &1.char_end) |> Enum.max(),
      token_count: members |> Enum.map(&UsageMeters.estimate_tokens(&1.text)) |> Enum.sum(),
      merged: true,
      members: Enum.map(members, &Map.delete(&1, :crumbed))
    })
  end

  # Review M2: each member's text, opened by its breadcrumb when its path
  # (title dropped) is deeper than its own heading and differs from the one
  # before. The first member has none: the group's prefix is its path.
  # Capped at the member's own prefix, so the group still fits the ceiling
  # `close_groups/2` sums from the members' inputs.
  defp with_crumbs([first | _] = members) do
    {out, _} =
      Enum.map_reduce(members, Map.get(first, :headings), fn m, prev ->
        hs = Map.get(m, :headings)

        crumbed =
          case hs do
            [_title, _, _ | _] when hs != prev ->
              room = byte_size(m.embed_text) - byte_size(m.text) - 2
              crumb = hs |> tl() |> Enum.join(" > ") |> valid_prefix(room)
              if crumb == "", do: m.text, else: crumb <> "\n" <> m.text

            _ ->
              m.text
          end

        {Map.put(m, :crumbed, crumbed), hs}
      end)

    out
  end

  defp valid_prefix(s, max) when byte_size(s) <= max, do: s
  defp valid_prefix(_s, max) when max <= 0, do: ""
  defp valid_prefix(s, max), do: s |> binary_part(0, max) |> String.chunk(:valid) |> hd()

  # The chunker builds each input as `prefix <> "\n\n" <> text`.
  # A copy, so the member's whole input is not kept alive by its prefix.
  defp prefix(input, text),
    do: :binary.copy(binary_part(input, 0, byte_size(input) - byte_size(text)))

  # A floor point and a merged one both keep their length out of `avgdl`
  # (NULL `token_count`) and encode with `cap_doc_len`.
  defp capped_length?(chunk), do: Map.get(chunk, :floor, false) or Map.get(chunk, :merged, false)

  @doc """
  Whether a full index of `planned_points` points for `note_id` fits the
  user's `index_points_cap`. The note's own rows are about to be replaced, so
  they do not count. True when the cap does not apply (billing disabled, or an
  unlimited plan). Counts inside `Repo.with_tenant/2`: unscoped, RLS filters
  the count to 0 and every pass would fit.

  `overshoot_pct` lets the count pass the cap by that share (the inline
  pass, see `over_points_budget_tier/3`).

  No lock: two concurrent passes can both fit on one reading, so the cap can
  be overshot by one note's chunks. Accepted.
  """
  @spec points_budget_ok?(map(), Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def points_budget_ok?(user, note_id, planned_points, overshoot_pct \\ 0) do
    case Engram.Billing.effective_limit(user, :index_points_cap) do
      cap when is_integer(cap) and cap >= 0 ->
        # All the user's rows minus this note's, not one `note_id !=` count:
        # that filter is not in `idx_chunks_user`, so it read every row from
        # the heap. The user count can be index-only on `idx_chunks_user`; the
        # note count reads only the note's own rows (at most its point cap).
        {:ok, [all, own]} =
          Repo.with_tenant(user.id, fn ->
            Repo.one(
              from(c in Chunk,
                where: c.user_id == ^user.id,
                select: [
                  count(),
                  subquery(from(o in Chunk, where: o.note_id == ^note_id, select: count()))
                ]
              )
            )
          end)

        all - own + planned_points <= cap + div(cap * overshoot_pct, 100)

      # nil / :unlimited / a negative sentinel: no ceiling.
      _ ->
        true
    end
  end

  @doc "The account's search points: its `chunks` rows, one per Qdrant point."
  @spec point_count(Ecto.UUID.t()) :: non_neg_integer()
  def point_count(user_id) do
    {:ok, n} =
      Repo.with_tenant(user_id, fn ->
        Repo.one(from(c in Chunk, where: c.user_id == ^user_id, select: count()))
      end)

    n
  end

  @doc "How many of the account's notes are on keyword-only search (a floor tier)."
  @spec floor_note_count(Ecto.UUID.t()) :: non_neg_integer()
  def floor_note_count(user_id) do
    {:ok, n} =
      Repo.with_tenant(user_id, fn ->
        Repo.one(
          from(n in Note,
            where:
              n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at) and
                n.index_tier in @floor_tiers,
            select: count()
          )
        )
      end)

    n
  end

  @doc """
  The floor tier a pass over `note` uses, or nil for a full pass.
  `opts[:index_tier]` wins over the note's own `index_tier`, so a caller can
  floor a note (or, with an explicit `nil`, promote it) in the same pass that
  stamps it.
  """
  @spec floor_tier(map(), keyword()) :: String.t() | nil
  def floor_tier(note, opts \\ []) do
    tier = Keyword.get(opts, :index_tier, Map.get(note, :index_tier))
    if tier in @floor_tiers, do: tier
  end

  # Body bytes one floor point covers. One vector for a whole note grew with
  # the note: a 3 MB CJK note (every bigram a term) was an 11.8 MB upsert
  # and a 213 MB encode peak, so 10 MB passed Qdrant's 32 MiB request cap
  # and 30 MB the worker's RAM. 1 MiB of text keeps a point near 4 MB of
  # JSON at that density.
  @floor_span 1_048_576

  @doc """
  Floor points a note whose body spans `span` bytes takes (`floor_plan/2`):
  about one per MiB, at least one. Exact as an upper bound for the body; a
  large frontmatter block can add a point. The index budget sweep projects
  a floor's cost with it.
  """
  @spec floor_points(non_neg_integer()) :: pos_integer()
  def floor_points(span), do: div(span, @floor_span - Markdown.max_chunk()) + 1

  @doc """
  The plan for a note over the Free index budget: one sparse-only point per
  MiB of the note's body (`floor_points/1`, so ONE for every note under
  1 MiB), keeping it keyword-searchable for the fewest points of budget.

  A point's keyword input is its chunks' `context_text` joined, so the
  vectors hold the union of the note's terms (headings and title prefix
  included). Chunks are packed in order, a point closing before its chunks'
  text would pass 1 MiB.
  It has no dense vector and no display text: its payload text is `""`, and a
  hit's snippet is the note's title and path from `notes`. The row's
  `token_count` is nil, so a whole-note length never enters the vault's
  `avgdl`, and the encoder normalizes it as if it were at most `avgdl` long
  (`cap_doc_len`). No `context_hmac`: nothing may reuse a floor point, and a
  later full pass deletes it as stale.
  """
  def floor_plan(note, chunks) do
    entries =
      chunks
      |> Enum.chunk_while(
        {[], 0},
        fn chunk, {acc, bytes} ->
          size = byte_size(chunk.text)

          if acc != [] and bytes + size > @floor_span,
            do: {:cont, Enum.reverse(acc), {[chunk], size}},
            else: {:cont, {[chunk | acc], bytes + size}}
        end,
        fn
          {[], _} -> {:cont, {[], 0}}
          {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
        end
      )
      |> Enum.with_index(fn members, position ->
        {:embed,
         %{
           position: position,
           char_start: members |> Enum.map(& &1.char_start) |> Enum.min(),
           char_end: members |> Enum.map(& &1.char_end) |> Enum.max(),
           heading_path: nil,
           text: "",
           embed_text: "",
           context_text: Enum.map_join(members, "\n\n", & &1.context_text),
           context_hmac: nil,
           kind: "prose",
           floor: true
         }}
      end)

    %{
      entries: entries,
      dense?: false,
      reused_point_ids: [],
      stale_point_ids: point_ids_for_note(note),
      # The floor chunk has no text to detect a language from.
      language: note_language(chunks)
    }
  end

  # Re-entrant inside commit_index/2's chunk transaction; on the purge path it
  # opens one of its own.
  defp run_in_commit(note, opts, chunk_count, dense?, index_tier) do
    case Keyword.get(opts, :in_commit) do
      nil -> :ok
      fun -> Repo.with_tenant!(note.user_id, fn -> fun.(chunk_count, dense?, index_tier) end)
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

  # Rows per chunk `insert_all`. A row binds 15 parameters (chunk_row/5 plus
  # the four chunk-text columns) against the protocol's 65535 cap, which
  # leaves room for 4369; 3000 keeps a margin (as Links' @insert_chunk) so a
  # new column cannot silently re-arm the overflow. Prod hit it at 73040
  # params (7,304 chunks, one note). The text columns add bytes, not
  # parameters: a batch carries at most the note's own text.
  @insert_batch 3000

  @doc """
  Phase 2 of the indexing pipeline. Applies the prepared structure: upserts the
  points for chunks that changed, PATCHes the note-level payload onto the ones
  being reused, rewrites the chunk rows, and deletes the points nothing names
  any more.

  Tenant context is handled internally: the chunk rewrite below opens its own
  `Repo.with_tenant/2`, so this is
  safe to call with or without an enclosing tenant (`with_tenant/2` is
  re-entrant for the same tenant, so a scoped caller pays nothing).

  This used to read "non-tenant-scoped callers run as the superuser role and
  bypass RLS". That was true of every environment and true of nothing in this
  code: under any role without SUPERUSER or BYPASSRLS the chunk insert raises
  42501. Scoping each write removes the dependency on how the app happens to
  connect.

  `in_commit` runs with the chunk count inside the chunk-row transaction, so
  a caller's own bookkeeping commits atomically with the rows.

  Returns `{:ok, chunk_count}` or `{:error, reason}`.
  """
  def commit_index(prepared, in_commit \\ fn _count -> :ok end)

  def commit_index(
        %{
          note: note,
          chunk_rows: chunk_rows,
          qdrant_points: qdrant_points,
          reused_point_ids: reused_point_ids,
          stale_point_ids: stale_point_ids,
          note_payload: note_payload,
          payload_hash: payload_hash
        } = prepared,
        in_commit
      ) do
    # Skip the PATCH when the note-level payload is what was last written:
    # on Qdrant 1.18 every set_payload target is copied into a new segment,
    # so an unconditional refresh rewrote the whole collection on each pass.
    refresh_ids = if payload_hash == note.payload_hash, do: [], else: reused_point_ids

    # Ordered so that every failure leaves STRAY points (which OrphanSweep
    # reaps) rather than a chunk row naming a point that is already gone —
    # which nothing self-heals and which reads as silently missing content.
    # That means the stale delete goes LAST, after the rows stop naming those
    # points. Deleting first and crashing before the row write would leave the
    # next attempt happily "reusing" ids that no longer exist in Qdrant.
    #
    # A floor plan reuses nothing, yet it skips the purge: its points are
    # written first and the dense points deleted only after the rows name them
    # (`drop_replaced_points/4`). A refused write (strict mode) then leaves the
    # old index whole, and a refused delete leaves both, still searchable.
    # A regroup (a merged plan, or a note leaving a floor or a merge) does the
    # same (review M4): merged fingerprints never reuse, so it used to purge
    # first and a refused upsert left the note with no points at all.
    floor? = Map.get(prepared, :index_tier) != nil or Map.get(prepared, :write_first, false)

    with :ok <-
           if(floor?,
             do: :ok,
             else: purge_before_rebuild(note, reused_point_ids, stale_point_ids)
           ),
         :ok <- upsert_points_batched(qdrant_points),
         # Reused points keep their vectors AND their ciphertext (every
         # encrypted field is inside `context_text`, so an equal hmac means an
         # identical payload), but the note-level filter keys on them are
         # note-level: a frontmatter tag edit changes ONE chunk while every
         # other point still answers tag filters with the pre-edit tags. One
         # PATCH refreshes the lot — the values are identical across a note's
         # points, which is why `chunk_index` no longer lives in the payload.
         :ok <- refresh_payload(prepared, refresh_ids, note_payload) do
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
      committed =
        Repo.with_tenant(note.user_id, fn ->
          content_current!(note)

          with {:ok, tier} <- Map.fetch(prepared, :index_tier),
               do: stamp_index_tier(note, tier, Map.get(prepared, :chunk_count))

          Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)
          # Batched inside the same transaction: one statement for a big note
          # overflows the protocol's bind cap and kills the connection.
          chunk_rows
          |> Enum.chunk_every(@insert_batch)
          |> Enum.each(&Repo.insert_all(Chunk, &1, skip_tenant_check: true))

          write_point_rows(note, Map.get(prepared, :point_rows))

          stamp_payload_hash(note, payload_hash)
          clear_rebuild_paid(prepared)
          stamp_okf_timestamp(prepared)
          stamp_flat_fields(prepared)
          in_commit.(length(chunk_rows))
        end)

      with {:ok, _} <- committed,
           :ok <-
             if(floor?,
               do: drop_replaced_points(note, stale_point_ids, qdrant_points, reused_point_ids),
               else: drop_stale_points(reused_point_ids, stale_point_ids, note)
             ) do
        # Only once the rows are committed: a failed attempt is retried, and
        # counting its upsert too would count the same points twice.
        emit_points_written(prepared)
        {:ok, length(chunk_rows)}
      end
    end
  end

  # Delete-then-insert per note, like `chunks`; nil (text off) leaves the
  # note's `chunk_points` as they are.
  defp write_point_rows(_note, nil), do: :ok

  defp write_point_rows(note, rows) do
    Repo.delete_all(from(p in ChunkPoint, where: p.note_id == ^note.id), skip_tenant_check: true)

    rows
    |> Enum.chunk_every(@insert_batch)
    |> Enum.each(&Repo.insert_all(ChunkPoint, &1, skip_tenant_check: true))
  end

  # The note's index is committed, so a Voyage payment for it is spent:
  # a later rebuild pass may pay again.
  defp clear_rebuild_paid(%{note: note} = prepared) do
    if Map.get(prepared, :rebuild?, false) or Map.get(note, :rebuild_paid_at) != nil,
      do: unstamp_rebuild_paid(note),
      else: :ok
  end

  defp unstamp_rebuild_paid(note) do
    {_, _} =
      Repo.update_all(
        from(n in Note,
          where: n.kind == "note" and n.id == ^note.id and not is_nil(n.rebuild_paid_at)
        ),
        set: [rebuild_paid_at: nil]
      )

    :ok
  end

  # Every point of the note now carries `note_payload`: upserted ones were
  # built from it, reused ones were just PATCHed (or already held it).
  defp stamp_payload_hash(%Note{payload_hash: hash}, hash), do: :ok

  defp stamp_payload_hash(note, hash) do
    {_, _} =
      Repo.update_all(
        from(n in Note, where: n.kind == "note" and n.id == ^note.id),
        set: [payload_hash: hash]
      )

    :ok
  end

  # One event per (kind, dense) pair, never per point. Only points written in
  # this commit: reused points have no `:point_kinds` entry.
  defp emit_points_written(%{point_kinds: point_kinds}) do
    for {{kind, dense?}, count} <- Enum.frequencies(point_kinds) do
      :telemetry.execute(
        [:engram, :indexing, :points_written],
        %{count: count},
        %{kind: kind, dense: to_string(dense?)}
      )
    end

    :ok
  end

  # A pass planned from content a newer edit has since replaced (a recap or
  # version rebuild running beside the edit's own EmbedNote) rolls back
  # rather than write its rows over the newer ones: the edit's pass already
  # stamped `embed_hash`, so nothing would re-select the note and its index
  # would stay stale. Its new points become strays for OrphanSweep. The row
  # lock holds off the edit until this commit. A struct with no hash (built
  # by hand) is not checked.
  defp content_current!(%{content_hash: hash} = note) when is_binary(hash) do
    current =
      Repo.one(
        from(n in Note,
          where: n.id == ^note.id and n.kind == "note",
          select: n.content_hash,
          lock: "FOR UPDATE"
        )
      )

    if current not in [nil, hash], do: Repo.rollback(:superseded)
    :ok
  end

  defp content_current!(_note), do: :ok

  # With the chunk rows, so the tier always names the rows that exist, and
  # compare-and-set on the tier this pass was planned from: if the index
  # budget demoted or promoted the note meanwhile (`ReconcileEmbeddings`), the
  # pass rolls back with `{:error, :index_tier_changed}` instead of
  # re-stamping it, and its retry plans from the new tier. The row lock holds
  # off a sweep stamp until commit. Writes only on a change.
  #
  # `tier_unchanged/1` already refused a race lost before planning; this one
  # can only lose to a sweep stamp landing during the Voyage and Qdrant
  # calls, which the sweep avoids for a note with a pass running.
  defp stamp_index_tier(note, tier, chunk_count) do
    expected = Map.get(note, :index_tier)

    case Repo.one(
           from(n in Note,
             where: n.id == ^note.id and n.kind == "note",
             select: {n.index_tier, n.chunk_count},
             lock: "FOR UPDATE"
           )
         ) do
      {^tier, ^chunk_count} when expected == tier ->
        :ok

      {^expected, _} ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id and n.kind == "note"),
          set: [index_tier: tier, chunk_count: chunk_count]
        )

      nil ->
        :ok

      {_changed, _} ->
        Repo.rollback(:index_tier_changed)
    end
  end

  # After a floor plan committed: the points its rows no longer name, then
  # anything else under the note's path but the new floor point (strays a
  # refused delete left behind). Returns an error so the job retries: the
  # rows already name the floor point, and an `index_budget: "demote"`
  # retry (or the next edit) re-floors and finishes the delete.
  defp drop_replaced_points(note, stale, points, reused) do
    with :ok <- Qdrant.delete_points(collection(), stale) do
      Qdrant.delete_by_note_except(
        collection(),
        to_string(note.user_id),
        to_string(note.vault_id),
        encode_hmac(note.path_hmac),
        Enum.map(points, & &1.id) ++ reused
      )
    end
  end

  # Bounded upsert bodies: thousands of 1024-dim float vectors as one JSON PUT
  # is tens of MB; Qdrant handles batches fine but the single request does not.
  # 64, not 256: JSON-encoding a batch is this process's heap peak (each float
  # becomes a list cell plus a formatted binary), and at 256 it measured ~54 MB
  # on its own. 64 keeps it ~4x lower for a few more round trips per big note.
  # Declared in Qdrant so the strict-mode limits are checked against it.
  @upsert_batch Qdrant.max_write_batch()

  # And bytes: 64 merged points of dense CJK (30 KB of text and ~10k terms
  # each) were an 8.75 MB request at 3 MB of note. A quarter of Qdrant's
  # 32 MiB request cap, so no note shape gets near it.
  @upsert_batch_bytes 8 * 1_048_576

  defp upsert_points_batched(points) do
    n = length(points)

    points
    |> point_batches()
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Qdrant.upsert_points(collection(), Enum.map(batch, &unpack_point/1)) do
        :ok -> {:cont, collect_garbage(n)}
        other -> {:halt, other}
      end
    end)
  end

  # Per-job memory on a huge note (chunker v5 Task 9.2). A pass allocates
  # several times the note in short-lived binaries (the parse, request JSON,
  # ciphertext), and a refc binary is freed only when the process that saw
  # it collects, so between collections that garbage piled up on top of
  # the live set: measured at 3 MB, ~10 MB of job memory per MB of note
  # before, ~8 after. A full sweep at each phase and after each Qdrant batch
  # caps it at the live set plus one batch. Costs a few ms a sweep, so only
  # a pass over more than `@collect_above` chunks or points pays it.
  # ponytail: explicit sweeps, not a restructure; build and upsert one batch
  # at a time (prepare/commit hand off the whole point list today) if the
  # live set itself ever outgrows the per-job budget.
  @collect_above 512

  defp collect_garbage(n) when n > @collect_above do
    :erlang.garbage_collect()
    :ok
  end

  defp collect_garbage(_n), do: :ok

  # At most `@upsert_batch` points and `@upsert_batch_bytes` of JSON each. A
  # point bigger than the byte budget goes alone (a floor point is bounded by
  # `@floor_span`).
  defp point_batches(points) do
    Enum.chunk_while(
      points,
      {[], 0, 0},
      fn point, {batch, count, bytes} ->
        size = point_json_bytes(point)

        if batch != [] and (count == @upsert_batch or bytes + size > @upsert_batch_bytes),
          do: {:cont, Enum.reverse(batch), {[point], 1, size}},
          else: {:cont, {[point | batch], count + 1, bytes + size}}
      end,
      fn
        {[], _, _} -> {:cont, {[], 0, 0}}
        {batch, _, _} -> {:cont, Enum.reverse(batch), {[], 0, 0}}
      end
    )
  end

  # An upper bound on a point's JSON, from what it holds before encoding: a
  # packed f32 (4 bytes) prints in at most 15 (`-1.2345678e-38,`), a packed
  # sparse entry (u32 index + f64 value, 12 bytes) in at most 36, a payload
  # string in its own bytes plus quotes and key.
  defp point_json_bytes(%{vector: named} = point) do
    vectors =
      for {_name, v} <- named, reduce: 0 do
        acc ->
          case v do
            v when is_binary(v) -> acc + div(byte_size(v), 4) * 15
            %{indices: i} when is_binary(i) -> acc + div(byte_size(i), 4) * 36
            v when is_list(v) -> acc + length(v) * 26
            %{indices: i} when is_list(i) -> acc + length(i) * 36
          end
      end

    vectors + payload_json_bytes(Map.get(point, :payload, %{})) + 256
  end

  defp payload_json_bytes(payload) do
    for {_key, v} <- payload, reduce: 0 do
      acc ->
        case v do
          v when is_binary(v) -> acc + byte_size(v) + 32
          v when is_list(v) -> acc + Enum.sum(Enum.map(v, &element_json_bytes/1)) + 32
          _ -> acc + 48
        end
    end
  end

  # A v5 long-tail entry (`%{"k" => id, "v" => id}`) is a small object: two
  # 32-char ids and framing, under 80 B.
  defp element_json_bytes(e) when is_map(e), do: 80
  defp element_json_bytes(e), do: byte_size(to_string(e)) + 4

  # Nothing reusable — every chunk is being rebuilt, so keep the belt-and-
  # braces purge this path has always run: by point id, AND by the path_hmac
  # filter, which is the only thing that reaches points whose chunk rows were
  # lost (a Postgres restore rolled back past the embed that wrote them).
  #
  # The reuse path cannot run that filter: it matches the note's points
  # wholesale, including the ones being kept. It relies on `OrphanSweep`'s
  # point pass for that class instead, which is the same reconciliation on a
  # weekly tick rather than per index.
  # Nothing reused, so the plan's stale ids are every point the chunk rows
  # name: `plan_chunks/4` already read them, and `delete_note_points/1` would
  # read them again in a tenant transaction of its own. The by-filter delete
  # still follows as the belt.
  defp purge_before_rebuild(note, [], stale_point_ids) do
    with :ok <- Qdrant.delete_points(collection(), stale_point_ids),
         do: delete_points_by_filter(note)
  end

  defp purge_before_rebuild(_note, _reused, _stale), do: :ok

  # Already handled wholesale by `purge_before_rebuild/3`.
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

  `repo` is required, with no default, because the pool must match the caller
  and getting it wrong is silent in the dangerous direction. `OrphanSweep`,
  the only production caller, passes note_ids spanning every tenant by
  construction, so no `with_tenant` is possible: it must pass
  `Repo.maintenance()`.

  Both writes below are `update_all` against tables carrying FORCE ROW LEVEL
  SECURITY. An `update_all` the policy filters does not raise: it reports
  `{0, nil}` and the caller logs success having changed nothing. `cross_tenant/1`
  does NOT prevent that — it only suppresses the app-level `prepare_query/3`
  tripwire and sets no Postgres session state. See engram-app/Engram#1746.
  """
  @spec flag_notes_for_rebuild([Ecto.UUID.t()], module()) :: non_neg_integer()
  def flag_notes_for_rebuild(note_ids, repo)

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
          Repo.delete_all(from(p in ChunkPoint, where: p.note_id == ^note.id))
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
    with :ok <- delete_points_for_note(note), do: delete_points_by_filter(note)
  end

  defp delete_points_by_filter(note) do
    Qdrant.delete_by_note(
      collection(),
      to_string(note.user_id),
      to_string(note.vault_id),
      encode_hmac(note.path_hmac)
    )
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
  @doc """
  Qdrant point ids recorded on `note`'s chunk rows, in chunk order.
  Tenant-scoped: unscoped, RLS filters this read to [] silently.
  """
  @spec point_ids_for_note(map()) :: [String.t()]
  def point_ids_for_note(note) do
    {:ok, point_ids} =
      Repo.with_tenant(note.user_id, fn ->
        Chunk
        |> where([c], c.note_id == ^note.id)
        |> order_by([c], c.position)
        |> select([c], c.qdrant_point_id)
        |> Repo.all()
      end)

    Enum.reject(point_ids, &is_nil/1)
  end

  @doc """
  `point_ids_for_note/1` narrowed to the points Qdrant holds a dense vector
  for. Frontmatter, data, canvas and base points are sparse-only.
  """
  @spec dense_point_ids_for_note(map()) :: {:ok, [String.t()]} | {:error, term()}
  def dense_point_ids_for_note(note) do
    Qdrant.dense_point_ids(collection(), point_ids_for_note(note))
  end

  defp delete_points_for_note(note) do
    Qdrant.delete_points(collection(), point_ids_for_note(note))
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

  @doc """
  The model this build embeds documents with, stamped on `notes.embed_model`
  by every dense pass. A note stamped with anything else is re-embedded by
  `ReconcileEmbeddings`.
  """
  #
  # Falls back to the embedder's own default, which is what it sends when
  # `EMBED_MODEL` is unset (the common self-host case), so a switch between
  # defaults is still a model change. nil only for an embedder with no
  # declared default (the test mock); model tracking is then off.
  @spec embed_model() :: String.t() | nil
  def embed_model do
    effective_embed_model() ||
      if Code.ensure_loaded?(embedder()) and function_exported?(embedder(), :default_model, 0),
        do: embedder().default_model()
  end

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
  #
  # The re-plan reuses the rows the dense plan read: a reservation, refused or
  # not, holds the meter row until the planning transaction commits, so on a
  # refusal nothing after it but CPU (fingerprints) may run under that lock.
  #
  # Third element: dense vectors an earlier attempt already paid for but did
  # not commit (`retain/1`, held across the commit). A hit skips the
  # reservation AND the embed, so a retry after any post-embed failure is
  # charged once.
  #
  # A v5 rebuild (`rebuild: true`, chunker v5 Task 16.3) only plans here:
  # its vectors are sourced after the planning transaction
  # (`rebuild_sources/6`), since the copy reads Qdrant.
  defp plan_within_budget(note, rows, chunks, content_key, dense?, opts) do
    if Keyword.get(opts, :rebuild, false),
      do:
        {dense?,
         chunks |> plan_chunks(rows, content_key, dense?) |> Map.put(:rebuild, {rows, chunks}),
         nil},
      else: budget_plan(note, rows, chunks, content_key, dense?, opts)
  end

  defp budget_plan(_note, rows, chunks, content_key, false, _opts),
    do: {false, plan_chunks(chunks, rows, content_key, false), nil}

  #
  # The user is charged for the chunks whose content changed, not for how we
  # grouped them (adversarial V3): a re-embedded merged group meters only its
  # members whose own fingerprint no stored row or member has. The rest of
  # what Voyage is sent is our maintenance, `[:engram, :embed, :maintenance]`.
  defp budget_plan(note, rows, chunks, content_key, true, opts),
    do: price(note, rows, chunks, content_key, plan_chunks(chunks, rows, content_key, true), opts)

  defp price(note, rows, chunks, content_key, plan, opts) do
    texts = embed_texts(plan)
    reserve = Keyword.get(opts, :reserve_tokens, fn _tokens -> true end)

    case retained(note, texts) do
      {:ok, vectors} ->
        {true, plan, vectors}

      :miss ->
        # Cache hits are free: only what Voyage will be sent is reserved. With
        # the cache, the user's share is summed over exactly the texts this
        # pass sends (`:charge_bytes`): a hit or a miss deferred past the pass
        # budget costs nothing until it is actually sent.
        cache = Keyword.get(opts, :vector_cache)
        user_bytes = if cache && budget_enabled?(), do: changed_bytes_per_text(plan, rows)
        plan = with_cache_lookup(plan, texts, cache, user_bytes)
        sent = Map.get_lazy(plan, :embed_bytes, fn -> text_bytes(texts) end)
        total = UsageMeters.estimate_tokens(sent)

        charged =
          cond do
            Map.has_key?(plan, :charge_bytes) ->
              min(UsageMeters.estimate_tokens(plan.charge_bytes), total)

            budget_enabled?() ->
              min(changed_tokens(plan, rows), total)

            true ->
              total
          end

        plan = Map.put(plan, :charge, {charged, total - charged})

        if charged > 0 and not reserve.(charged) do
          {false, plan_chunks(chunks, rows, content_key, false), nil}
        else
          maintenance_tokens(total - charged)
          {true, plan, nil}
        end
    end
  end

  defp retained_or_embed(nil, dense?, plan, texts, opts),
    do: embed_or_release(dense?, plan, texts, opts)

  defp retained_or_embed(vectors, _dense?, _plan, _texts, _opts), do: {:ok, vectors}

  # ---------------------------------------------------------------------------
  # v5 rebuild of one note (chunker v5 Task 16.3)
  # ---------------------------------------------------------------------------

  # Every point is written fresh (a UUIDv5 id, the v5 payload): nothing is
  # reused in place, and every old id is deleted after the new rows commit
  # (`write_first`). Each dense vector comes from, in order: the old point
  # with the same fingerprint (the old `chunks.context_hmac`); the vector
  # cache; the normalized mean of a capped group's members' old points, when
  # every member has one (C13); else Voyage. Sparse vectors are local.
  defp rebuild_sources(note, dense?, %{rebuild: {rows, chunks}} = plan, _retained, ck, opts) do
    old = for {hmac, id, _tokens, _members} <- rows, id != nil, do: {hmac, id}
    by_member = for {hmac, id} <- old, hmac != nil, into: %{}, do: {short_hmac(hmac), id}
    sources = Enum.map(plan.entries, &old_sources(&1, dense?, by_member))

    with {:ok, found} <- old_dense(Enum.uniq(List.flatten(sources)), dense?) do
      plan =
        plan
        |> Map.delete(:rebuild)
        |> Map.merge(%{
          entries: Enum.zip_with(plan.entries, sources, &fresh_entry(&1, &2, found)),
          reused_point_ids: [],
          stale_point_ids: Enum.map(old, &elem(&1, 1)),
          rebuild?: true
        })

      if dense?,
        do: priced_rebuild(note, rows, chunks, ck, plan, opts),
        else: {:ok, false, plan, nil}
    end
  end

  defp rebuild_sources(_note, dense?, plan, retained, _ck, _opts),
    do: {:ok, dense?, plan, retained}

  # Priced like any pass (the reservation is maintenance for a dense note),
  # over only what is left to send. A refusal re-plans sparse-only, and that
  # plan is a rebuild too.
  defp priced_rebuild(note, rows, chunks, ck, plan, opts) do
    case Repo.with_tenant!(note.user_id, fn -> price(note, rows, chunks, ck, plan, opts) end) do
      {false, sparse, nil} ->
        rebuild_sources(note, false, Map.put(sparse, :rebuild, {rows, chunks}), nil, ck, opts)

      {dense?, plan, retained} ->
        {:ok, dense?, plan, retained}
    end
  end

  # The old point ids a planned entry's dense vector can come from.
  defp old_sources({:reuse, chunk, id, _tokens}, dense?, _by_member),
    do: if(dense_chunk?(chunk, dense?), do: [id], else: [])

  defp old_sources({:embed, %{merged: true, member_hmacs: hmacs} = chunk}, dense?, by_member) do
    ids = Enum.map(hmacs, &Map.get(by_member, &1))
    if dense_chunk?(chunk, dense?) and nil not in ids, do: ids, else: []
  end

  defp old_sources(_entry, _dense?, _by_member), do: []

  defp old_dense([], _dense?), do: {:ok, %{}}
  defp old_dense(_ids, false), do: {:ok, %{}}

  # Paged like an upsert, so a response stays a few MB of vectors.
  defp old_dense(ids, true) do
    ids
    |> Enum.chunk_every(Qdrant.max_write_batch())
    |> Enum.reduce_while({:ok, %{}}, fn page, {:ok, acc} ->
      case Qdrant.retrieve(collection(), page, with_vector: true) do
        {:ok, points} ->
          {:cont,
           {:ok, for(%{qdrant_id: id, vector: [_ | _] = d} <- points, into: acc, do: {id, d})}}

        other ->
          {:halt, other}
      end
    end)
  end

  defp fresh_entry({:reuse, chunk, _id, _tokens}, ids, found),
    do: fresh_entry({:embed, chunk}, ids, found)

  defp fresh_entry({:embed, chunk}, [], _found), do: {:embed, chunk}

  defp fresh_entry({:embed, chunk}, ids, found) do
    vectors = Enum.map(ids, &Map.get(found, &1))

    vector =
      case vectors do
        [single] -> single
        _ -> if nil not in vectors, do: unit_mean(vectors)
      end

    if vector, do: {:embed, Map.put(chunk, :vector, pack_vector(vector))}, else: {:embed, chunk}
  end

  # ponytail: Elixir floats over a group's members (a few to a few hundred
  # 1024-dim vectors); move to a NIF if it shows in a rebuild profile.
  defp unit_mean(vectors) do
    sum = Enum.zip_with(vectors, &Enum.sum/1)
    norm = :math.sqrt(Enum.reduce(sum, 0.0, &(&1 * &1 + &2)))
    if norm > 0, do: Enum.map(sum, &(&1 / norm))
  end

  # A rebuild pays Voyage at most once per note until its index commits
  # (`notes.rebuild_paid_at`, cleared by `clear_rebuild_paid/1`). A retry
  # whose vectors were retained or cached sends nothing and is not checked.
  defp paid_once(note, retained, dense?, %{rebuild?: true} = plan, texts, opts) do
    to_send = if match?(%{cache: _}, plan), do: plan.cache.send, else: texts
    sends? = dense? and is_nil(retained) and to_send != []

    cond do
      not sends? ->
        retained_or_embed(retained, dense?, plan, texts, opts)

      Map.get(note, :rebuild_paid_at) != nil ->
        Rebuild.park_double_pay(note)

      true ->
        with {:ok, _vectors} = ok <- retained_or_embed(retained, dense?, plan, texts, opts) do
          {:ok, _} =
            Repo.with_tenant(note.user_id, fn ->
              Repo.update_all(from(n in Note, where: n.kind == "note" and n.id == ^note.id),
                set: [rebuild_paid_at: DateTime.utc_now()]
              )
            end)

          ok
        end
    end
  end

  defp paid_once(_note, retained, dense?, plan, texts, opts),
    do: retained_or_embed(retained, dense?, plan, texts, opts)

  # ponytail: node-local, 30 min TTL, byte-capped (RetainedVectors). A retry on
  # another node, after the TTL, or after a cap eviction re-pays Voyage for that
  # note. Oban's default backoff puts all five attempts inside the TTL. Persist
  # them (chunks table) if failures get common.
  # Over iodata, length-prefixed: `term_to_binary` built a copy of every
  # text (30 MB at 30 MB) just to hash it.
  defp retained_key(note, texts) do
    lengths = Enum.map(texts, &[Integer.to_string(IO.iodata_length(&1)), ":", &1])
    {note.id, :crypto.hash(:sha256, [to_string(pass_model()), "\n" | lengths])}
  end

  defp retained(_note, []), do: :miss
  defp retained(note, texts), do: RetainedVectors.get(retained_key(note, texts))

  defp retain(nil), do: :ok
  defp retain({key, vectors}), do: RetainedVectors.put(key, vectors)

  defp forget_retained(nil), do: :ok
  defp forget_retained({key, _vectors}), do: RetainedVectors.forget(key)

  # Estimated tokens of the embed entries' chunks, or of a merged one's
  # members, whose fingerprint (leading 16 hex chars) the stored rows do
  # not hold, as a point's own or among a merged point's members.
  defp changed_tokens(plan, rows),
    do: plan |> changed_bytes_per_text(rows) |> Enum.sum() |> UsageMeters.estimate_tokens()

  # The changed bytes of each dense text, in `embed_texts/1` order: what the
  # user is charged for when that text is sent. Only what Voyage is sent
  # counts, so a keyword-only chunk or group has no entry.
  defp changed_bytes_per_text(plan, rows) do
    known = known_hmacs(rows)
    new? = &(not MapSet.member?(known, &1))

    for {:embed, chunk} <- plan.entries,
        sent?(chunk, plan.dense?),
        do: chunk |> changed_bytes(new?) |> Enum.sum()
  end

  # Every short fingerprint the stored rows hold, a point's own or a merged
  # point's members'.
  defp known_hmacs(rows),
    do:
      MapSet.new(
        for {hmac, _point_id, _tokens, members} <- rows,
            h <- [hmac && short_hmac(hmac) | members || []],
            h != nil,
            do: h
      )

  defp changed_bytes(%{merged: true, member_bytes: bytes, member_hmacs: hmacs}, new?),
    do: for({b, h} <- Enum.zip(bytes, hmacs), new?.(h), do: b)

  defp changed_bytes(chunk, new?),
    do: if(new?.(short_hmac(chunk.context_hmac)), do: [byte_size(chunk.embed_text)], else: [])

  defp short_hmac(hmac), do: binary_part(hmac, 0, min(16, byte_size(hmac)))

  defp maintenance_tokens(0), do: :ok

  defp maintenance_tokens(tokens),
    do: :telemetry.execute([:engram, :embed, :maintenance], %{tokens: tokens}, %{})

  # Anything but a successful embed gives its reservation back, exactly once:
  # an `{:error, _}`, a raise, a throw or an exit. The `catch` re-raises with
  # the original stacktrace, so callers see the same failure. A failure AFTER
  # the embed (the Qdrant commit) keeps the charge: Voyage billed those tokens.
  #
  # Not covered: a hard node kill (or a brutal kill of the job process, e.g. an
  # Oban timeout) between the reservation and the embed returning — no code
  # runs, so that pass's tokens stay charged. Accepted: rare, and bounded to one
  # note's worth of tokens per kill.
  # `{bytes, user_bytes}` of the dense texts this pass has sent Voyage so far
  # (`embed_misses/1`), the second being the user-chargeable part.
  # Process-scoped so the release can read it after a raise as well as after
  # an `{:error, _}`. Always `{0, 0}` without the cache.
  @paid_bytes_key {__MODULE__, :vector_cache_paid_bytes}

  defp embed_or_release(false, _plan, texts, _opts), do: maybe_embed(false, texts)

  defp embed_or_release(true, plan, texts, opts) do
    {charged, maintenance} = Map.get(plan, :charge, {0, 0})

    # Gives back only what Voyage was NOT sent. With the vector cache, the
    # batches that returned before the failure were paid and cached: the
    # retry finds them as hits and reserves nothing for them, so they stay
    # charged here, exactly once. The user keeps the charge for the changed
    # bytes those batches carried, never for our maintenance texts in them.
    # A batch whose cache write was skipped (rotation, deleted note) still
    # stays charged: Voyage was paid for it, and its retry pays again.
    release = fn ->
      {paid_bytes, paid_user_bytes} = Process.get(@paid_bytes_key, {0, 0})
      paid = UsageMeters.estimate_tokens(paid_bytes)
      keep_charged = min(charged, UsageMeters.estimate_tokens(paid_user_bytes))
      keep_maintenance = min(maintenance, max(paid - keep_charged, 0))
      refund = charged - keep_charged

      if refund > 0, do: Keyword.get(opts, :release_tokens, fn _tokens -> :ok end).(refund)
      maintenance_tokens(-(maintenance - keep_maintenance))
    end

    Process.put(@paid_bytes_key, {0, 0})

    result =
      try do
        embed_dense(plan, texts, opts)
      catch
        kind, reason ->
          release.()
          Process.delete(@paid_bytes_key)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    # `:embed_continues` embedded (and cached) exactly what it reserved.
    with {:error, reason} when reason != :embed_continues <- result, do: release.()
    Process.delete(@paid_bytes_key)
    result
  end

  # ---------------------------------------------------------------------------
  # Vector cache (chunker v5 Task 12, `Engram.Indexing.VectorCache`)
  # ---------------------------------------------------------------------------

  # Off: `opts` unchanged, and nothing below runs, so the pass is the
  # pre-cache one byte for byte.
  defp with_vector_cache(user, note, content_key, dims, opts) do
    if VectorCache.enabled?() and Keyword.get(opts, :dense, true) do
      with {:ok, dek} <- Crypto.get_dek(user) do
        cache = %{
          user_id: note.user_id,
          note_id: note.id,
          dek: dek,
          dek_version: user.dek_version || 1,
          content_key: content_key,
          key_opts: [model: pass_model(), dims: dims, dtype: "float", input_type: "document"]
        }

        {:ok, Keyword.put(opts, :vector_cache, cache)}
      end
    else
      {:ok, opts}
    end
  end

  # ONE query for every dense text of the pass. Misses are deduplicated by
  # key (a note repeating a section embeds it once) and taken in note order up
  # to the pass byte budget; any left over make the pass `:continues`.
  defp with_cache_lookup(plan, _texts, nil, _user_bytes), do: plan

  # `user_bytes`: each text's chargeable bytes (budget on), or nil for
  # "all of it" (budget off: the user pays for everything sent).
  defp with_cache_lookup(plan, texts, cache, user_bytes) do
    user_bytes = user_bytes || Enum.map(texts, &IO.iodata_length/1)

    pairs =
      Enum.zip_with(texts, user_bytes, fn text, ub ->
        digest = VectorCache.digest(text, cache.key_opts)
        {VectorCache.key_for_digest(cache.content_key, digest), digest, text, ub}
      end)

    keys = Enum.map(pairs, &elem(&1, 0))
    hits = VectorCache.get_many(cache.user_id, cache.dek, keys)
    budget = max_pass_embed_bytes()

    # A text repeated in the note is sent once and charged once, at the
    # largest share any of its copies carries.
    {send, deferred?, bytes} =
      pairs
      |> Enum.reject(fn {key, _d, _t, _ub} -> Map.has_key?(hits, key) end)
      |> Enum.group_by(&elem(&1, 0))
      |> then(fn groups ->
        pairs
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.flat_map(fn key ->
          case groups do
            %{^key => [{k, d, t, _} | _] = copies} ->
              [{k, d, t, copies |> Enum.map(&elem(&1, 3)) |> Enum.max()}]

            _hit ->
              []
          end
        end)
      end)
      |> Enum.reduce({[], false, 0}, fn {_k, _d, text, _ub} = miss, {acc, deferred?, used} ->
        size = IO.iodata_length(text)

        if acc != [] and used + size > budget,
          do: {acc, true, used},
          else: {[miss | acc], deferred?, used + size}
      end)

    send = Enum.reverse(send)

    Map.merge(plan, %{
      cache:
        Map.merge(cache, %{
          keys: keys,
          hits: hits,
          send: send,
          continues: deferred?
        }),
      embed_bytes: bytes,
      charge_bytes: send |> Enum.map(&elem(&1, 3)) |> Enum.sum()
    })
  end

  defp embed_dense(%{cache: cache}, _texts, opts) do
    with {:ok, fresh} <- embed_misses(cache, opts) do
      if cache.continues,
        do: {:error, :embed_continues},
        else: {:ok, Enum.map(cache.keys, &(Map.get(cache.hits, &1) || Map.fetch!(fresh, &1)))}
    end
  end

  defp embed_dense(_plan, texts, opts), do: embed_for_indexing(texts, opts)

  # Each Voyage batch is cached the moment it returns, before Qdrant or the
  # chunk rows: a 429 on batch 3, a crash before commit or a retry on another
  # node pays only for the batches not yet cached.
  defp embed_misses(cache, opts) do
    cache.send
    |> batch_texts(fn {_key, _digest, text, _ub} -> IO.iodata_length(text) end)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, acc} ->
      with {:ok, vectors} <- do_embed_batch(Enum.map(batch, &elem(&1, 2)), opts),
           :ok <- same_count(vectors, batch) do
        entries =
          Enum.zip_with(batch, vectors, fn {key, digest, _text, _ub}, v ->
            {key, digest, pack_vector(v)}
          end)

        :ok =
          VectorCache.put_many(
            cache.user_id,
            cache.note_id,
            cache.dek,
            entries,
            cache.dek_version
          )

        {paid, paid_user} = Process.get(@paid_bytes_key, {0, 0})

        sent =
          batch |> Enum.map(fn {_k, _d, text, _ub} -> IO.iodata_length(text) end) |> Enum.sum()

        user = batch |> Enum.map(&elem(&1, 3)) |> Enum.sum()
        Process.put(@paid_bytes_key, {paid + sent, paid_user + user})
        {:cont, {:ok, Enum.into(entries, acc, fn {key, _digest, v} -> {key, v} end)}}
      else
        other -> {:halt, other}
      end
    end)
  end

  defp same_count(vectors, batch) when length(vectors) == length(batch), do: :ok

  defp same_count(vectors, batch),
    do: {:error, {:embed_count_mismatch, length(vectors), length(batch)}}

  defp text_bytes(texts), do: texts |> Enum.map(&IO.iodata_length/1) |> Enum.sum()

  # `false` yields a nil vector per chunk. Kept as an explicit list (not a bare
  # nil) so build_prepared/8 can zip chunks with vectors either way.
  defp maybe_embed(false, texts), do: {:ok, Enum.map(texts, fn _ -> nil end)}

  # A dense vector is held as packed float32 between the embed call and the
  # Qdrant upsert, not as the embedder's float list. As a list each element
  # costs a cons cell plus a boxed float (~32 bytes on the process heap); packed
  # it is 4 bytes in an off-heap binary. The whole note's vectors live until
  # commit, so for a 2,000-chunk note that is ~65 MB of heap versus ~8 MB
  # off-heap (prod worker OOM, 2026-10-03). Lossless: Voyage's floats ARE
  # float32. Unpacked one upsert batch at a time in `upsert_points_batched/1`.
  # An embedder may already return packed float32 (Voyage does, for indexing).
  defp pack_vector(packed) when is_binary(packed), do: packed
  defp pack_vector(vector), do: Engram.Native.pack_f32(vector)

  # Straight from the packed binary to the JSON array text, as a pre-encoded
  # fragment. Unpacking to a float list and letting Jason walk it was the heap
  # peak of indexing (~26 MB per 64-point batch): a list cell, a boxed float
  # and a formatted binary per element, all live until the request was sent.
  #
  # The encrypted payload fields are base64 (`Crypto.encrypt_qdrant_payload/4`),
  # whose alphabet never needs a JSON escape, so they go out as fragments too:
  # Jason's escape scan over them cost ~35-45 ms per 2,000 chunks (#1877).
  # Byte-identical output; `test/engram/indexing/unpack_point_test.exs` pins it.
  @doc false
  def unpack_point(%{vector: named} = point) do
    point = %{point | vector: Map.new(named, fn {name, v} -> {name, vector_json(v)} end)}

    case point do
      %{payload: payload} -> %{point | payload: base64_fragments(payload)}
      _ -> point
    end
  end

  @base64_payload_keys [
    :text,
    :text_nonce,
    :title,
    :title_nonce,
    :heading_path,
    :heading_path_nonce
  ]

  # A value holding a byte JSON must escape is not the base64
  # `encrypt_qdrant_payload/4` promises, so it goes through Jason rather than
  # being spliced raw into the request body. The `:binary.match` scan keeps
  # about 40% of the fragment gain (2,000 chunks, min of 7, three runs:
  # Jason 33-34 ms, guarded 25-27 ms, unguarded 10-11 ms); the rest is the
  # price of not trusting the caller. Compiling the pattern costs ~70 us,
  # more than a scan, so it is compiled once per node.
  defp base64_fragments(payload) do
    escape = json_escape_pattern()

    Enum.reduce(@base64_payload_keys, payload, fn key, acc ->
      case acc do
        %{^key => b64} when is_binary(b64) ->
          if :binary.match(b64, escape) == :nomatch,
            do: %{acc | key => Jason.Fragment.new([?", b64, ?"])},
            else: acc

        _ ->
          acc
      end
    end)
  end

  defp json_escape_pattern do
    with nil <- :persistent_term.get(__MODULE__.JsonEscape, nil) do
      pattern = :binary.compile_pattern([~s("), "\\" | Enum.map(0..31, &<<&1>>)])
      :persistent_term.put(__MODULE__.JsonEscape, pattern)
      pattern
    end
  end

  # Formatted in Rust (`Engram.Native.dense_json/1`): no per-float term at all,
  # and each value printed as its shortest f32 decimal, half the text of the
  # widened-f64 form for the same stored f32.
  defp vector_json(dense) when is_binary(dense),
    do: Jason.Fragment.new(Engram.Native.dense_json(dense))

  # Packed sparse (`KeywordIndex.packed_sparse`), written straight to JSON for
  # the same reason as the dense leg.
  defp vector_json(%{indices: indices, values: values}) when is_binary(indices),
    do: Jason.Fragment.new(Engram.Native.sparse_json(indices, values))

  defp embed_for_indexing(texts, opts) do
    n = length(texts)

    texts
    |> batch_texts()
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case do_embed_batch(batch, opts) do
        {:ok, vectors} ->
          :ok = collect_garbage(n)
          {:cont, {:ok, [Enum.map(vectors, &pack_vector/1) | acc]}}

        other ->
          {:halt, other}
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
  defp batch_texts(texts, size_of \\ &IO.iodata_length/1) do
    Enum.chunk_while(
      texts,
      {[], 0, 0},
      fn text, {batch, count, bytes} ->
        size = size_of.(text)

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

  # A merged input is iodata until its batch goes out. `:embed_purpose`
  # (`:maintenance` for a RebuildStaleNote pass) picks the embedder's request
  # defaults; with neither it nor a doc model the call is the bare one.
  defp do_embed_batch(texts, opts) do
    texts = Enum.map(texts, &IO.iodata_to_binary/1)

    case Enum.reject(
           [
             model: Process.get(@pass_model_key) || doc_embed_model(),
             purpose: opts[:embed_purpose]
           ],
           &is_nil(elem(&1, 1))
         ) do
      [] -> embedder().embed_texts(texts)
      embed_opts -> embedder().embed_texts(texts, embed_opts)
    end
  end

  # Decides, per chunk, whether it can keep the point it already has (#1592).
  #
  # The fingerprint is over `context_text` ("folder > title > heading\n\ntext",
  # the keyword input) and `embed_text` (the dense input), NOT the bare chunk
  # text. That distinction is the whole correctness argument: an equal pair
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
  defp plan_chunks(chunks, rows, content_key, dense?) do
    chunks =
      Enum.zip_with(chunks, plan_fingerprints(content_key, chunks, dense?), fn chunk, hmac ->
        Map.put(chunk, :context_hmac, hmac)
      end)
      |> with_member_hmacs(content_key, dense?)
      |> Enum.map(&drop_members/1)

    existing =
      for {hmac, point_id, tokens, _members} <- rows,
          point_id != nil,
          do: {hmac, point_id, tokens}

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
      dense?: dense?,
      reused_point_ids: reused,
      stale_point_ids: Enum.map(existing, fn {_h, id, _t} -> id end) -- reused
    }
  end

  # Tenant-scoped: unscoped this read is filtered to [], so reuse never
  # matches. That is not a correctness break but a cost one: every index
  # pays a full re-embed, and the prior pass's points are left orphaned in
  # Qdrant rather than being reused or replaced.
  defp indexed_rows(note) do
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Chunk
        |> where([c], c.note_id == ^note.id)
        |> select([c], {c.context_hmac, c.qdrant_point_id, c.token_count, c.member_hmacs})
        |> Repo.all()
      end)

    rows
  end

  # What a point HOLDS is part of the fingerprint, not just its text (#1606).
  # A sparse-only point has no dense vector: matching it on a dense pass
  # stamped the note densely indexed with nothing behind the stamp, and a
  # sparse-only pass kept vectors it had decided not to pay for. The model is in it for
  # the same reason, since another model's vector is not reusable either.
  #
  # One NIF call for the whole note (`Engram.Native.hmac_hex_many/3`): the same
  # hex HMAC as `Crypto.hmac_content_hash/2` over `prefix <> context_text`,
  # without building each prefixed copy or hex-encoding in Elixir.
  #
  # Per chunk on a dense pass: only prose gets a dense vector, so the rest are
  # fingerprinted as the sparse-only points they become, and a chunk whose kind
  # changes never reuses a point of the other shape.
  defp plan_fingerprints(content_key, chunks, dense?) do
    {dense, sparse} = Enum.split_with(chunks, &dense_chunk?(&1, dense?))

    {hmacs, {[], []}} =
      Enum.map_reduce(
        chunks,
        {fingerprints(content_key, dense, true), fingerprints(content_key, sparse, false)},
        fn chunk, {d, s} ->
          if dense_chunk?(chunk, dense?), do: {hd(d), {tl(d), s}}, else: {hd(s), {d, tl(s)}}
        end
      )

    hmacs
  end

  defp dense_chunk?(chunk, dense?),
    do: dense? and Markdown.dense_kind?(chunk.kind) and not Map.get(chunk, :sparse_only, false)

  # A dense chunk Voyage (or the vector cache) must supply: not one whose
  # vector a v5 rebuild already sourced from Qdrant (`rebuild_sources/6`).
  defp sent?(chunk, dense?), do: dense_chunk?(chunk, dense?) and not Map.has_key?(chunk, :vector)

  # A merged chunk's point holds a length-capped keyword vector and no
  # `avgdl` length, so it never matches an unmerged chunk with the same
  # text, or the reverse: `merged/` in front, decided per chunk. A group of
  # one is an unmerged chunk and keeps the plain fingerprint, so it reuses.
  defp fingerprints(content_key, chunks, dense?) do
    prefix = fingerprint_prefix(dense?)
    merged? = &Map.get(&1, :merged, false)
    {merged, plain} = Enum.split_with(chunks, merged?)

    hmacs = &hmac_inputs(content_key, &1, Enum.map(&2, fn c -> {:input, c} end))

    restitch(chunks, merged?, hmacs.("merged/" <> prefix, merged), hmacs.(prefix, plain))
  end

  # Each merged chunk's members' own fingerprints (the ones they would have
  # unmerged), leading 16 hex chars: what `chunks.member_hmacs` stores. A
  # member is dense (dense prefix) when its group is and it is prose: a
  # table inside a prose group would be a keyword-only point on its own.
  defp with_member_hmacs(chunks, content_key, dense?) do
    members =
      for %{merged: true, members: ms} = c <- chunks,
          m <- ms,
          do: {m, dense_chunk?(c, dense?) and m.kind == "prose"}

    {dense, sparse} = Enum.split_with(members, &elem(&1, 1))
    hmacs = &hmac_inputs(content_key, fingerprint_prefix(&2), for({m, _} <- &1, do: {:input, m}))
    all = restitch(members, &elem(&1, 1), hmacs.(dense, true), hmacs.(sparse, false))

    {chunks, []} =
      Enum.map_reduce(chunks, all, fn
        %{merged: true, members: ms} = chunk, left ->
          {mine, rest} = Enum.split(left, length(ms))
          {Map.put(chunk, :member_hmacs, Enum.map(mine, &short_hmac/1)), rest}

        chunk, left ->
          {chunk, left}
      end)

    chunks
  end

  # A planned merged chunk keeps only what metering reads of its members
  # (`changed_bytes/2`): holding the member chunks kept every original
  # text, context_text and embed_text alive next to the merged copies, ~3x
  # the note on the job until commit (Task 9.2).
  defp drop_members(%{members: members} = chunk) do
    chunk
    |> Map.delete(:members)
    |> Map.put(:member_bytes, Enum.map(members, &member_bytes/1))
  end

  defp drop_members(chunk), do: chunk

  # What a member adds to its group's dense input: nothing unless prose.
  defp member_bytes(%{kind: "prose", embed_text: e}), do: byte_size(e)
  defp member_bytes(_member), do: 0

  # `hmac_hex_many/3` over each chunk's `fingerprint_input/1`, 256 at a time:
  # the inputs are copies (context + embed text), so building them for a
  # whole 30 MB note at once held ~60 MB extra on the job (Task 9.2).
  @hmac_slice 256

  defp hmac_inputs(key, prefix, inputs) do
    inputs
    |> Enum.chunk_every(@hmac_slice)
    |> Enum.flat_map(fn slice ->
      Engram.Native.hmac_hex_many(
        key,
        prefix,
        for({:input, c} <- slice, do: fingerprint_input(c))
      )
    end)
  end

  # Results computed separately for the chunks `pred` holds for (`yes`) and
  # the rest (`no`), each in `chunks` order, merged back into that order.
  defp restitch(chunks, pred, yes, no) do
    {out, {[], []}} =
      Enum.map_reduce(chunks, {yes, no}, fn chunk, {y, n} ->
        if pred.(chunk), do: {hd(y), {tl(y), n}}, else: {hd(n), {y, tl(n)}}
      end)

    out
  end

  # One encode call per distinct `sparse_opts/1` (plain chunks, merged
  # groups, floor points), results back in `chunks` order. The plain group
  # calls the /4 arity: test doubles implement only that one.
  defp encode_sparse(chunks, filter_key, avgdl, language) do
    chunks
    |> Enum.with_index()
    |> Enum.group_by(fn {chunk, _i} -> sparse_opts(chunk) end)
    |> Enum.flat_map(fn {opts, group} ->
      texts = Enum.map(group, fn {chunk, _i} -> chunk.context_text end)

      vectors =
        if opts == [],
          do: KeywordIndex.module().encode_documents(texts, filter_key, avgdl, language),
          else: KeywordIndex.module().encode_documents(texts, filter_key, avgdl, language, opts)

      Enum.zip_with(group, vectors, fn {_chunk, i}, vector -> {i, vector} end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Keyword encoder options for a chunk (plan Task 14.1). Floor and capped
  groups encode length-capped (`cap_doc_len`). When the v5 layout is
  written (`:write_v5_layout`), a chunk joining more than one section
  (`section_count > 1`: a v5 min512 chunk or a capped group) scores with
  BM25 `b` = `ServiceConfig.get(:bm25_b_merged, 0.25)`; everything else, and
  every v3 write, keeps the encoder's 0.75, byte-identical to before.
  """
  @spec sparse_opts(map()) :: keyword()
  def sparse_opts(chunk) do
    cap = if capped_length?(chunk), do: [cap_doc_len: true], else: []

    # The same flag as `Qdrant.write_v5_layout?/0` (PR-15b); switch to that
    # accessor when both are on one branch.
    if Engram.ServiceConfig.get(:write_v5_layout, false) == true and
         Map.get(chunk, :section_count, 1) > 1,
       do: cap ++ [b: Engram.ServiceConfig.get(:bm25_b_merged, 0.25)],
       else: cap
  end

  @doc """
  The vault's BM25 `avgdl`, the one source every keyword encode reads: the
  cached `KeywordIndex.Stats.avgdl/2`, except while the v5 rebuild is `on`,
  when it is the value the dry run pinned (`rebuild_manifest_vaults`, spec
  K2, H14), so a note indexed at the end of the pass is normalized like one
  indexed at its start. A vault with no pin keeps the live value.
  """
  @spec avgdl(Ecto.UUID.t(), Ecto.UUID.t()) :: float()
  def avgdl(user_id, vault_id) do
    pinned = if Engram.Rebuild.mode() == :on, do: Engram.Rebuild.pinned_avgdl(user_id, vault_id)

    case pinned do
      avgdl when is_float(avgdl) -> avgdl
      nil -> Engram.KeywordIndex.Stats.avgdl(user_id, vault_id)
    end
  end

  @doc """
  The v5 rebuild dry run's estimate for one note: what a rebuild pass would
  write and send Voyage, from the same parse, cap plan and reuse
  fingerprints as `prepare_index/4`, with no Voyage and no Qdrant call.

    * `est_tokens`: estimated tokens of the dense texts Voyage would be sent
      (vector cache hits are not counted: an upper bound).
    * `new_points`: points that need a new vector (or are keyword-only).
    * `reused_points`: points whose fingerprint is unchanged (vector copied).
    * `mean_pooled_points`: merged groups whose members all have a stored
      vector (C13, the normalized mean): no tokens.
    * `dl_sum`, `dl_count`: keyword lengths of the planned points that
      count toward `avgdl` (not merged, not floor).

  Planned with `version_rebuild_opts/1`, the opts the version rebuild
  runs with, so the estimate and the pass agree on what is dense. `note` is
  decrypted.
  """
  @spec rebuild_estimate(map(), map()) :: {:ok, %{atom() => non_neg_integer()}} | {:error, term()}
  def rebuild_estimate(note, user) do
    zero = %{
      est_tokens: 0,
      new_points: 0,
      reused_points: 0,
      mean_pooled_points: 0,
      dl_sum: 0,
      dl_count: 0
    }

    # The owner's plan model: the reuse fingerprints name it, as in the pass.
    with {:ok, content_key} <- Crypto.dek_content_hash_key(user) do
      case Markdown.parse(note.content || "", note.path) do
        [] ->
          {:ok, zero}

        chunks ->
          with_pass_model(user, [], fn ->
            {:ok, estimate_chunks(note, user, chunks, content_key, zero)}
          end)
      end
    end
  end

  defp estimate_chunks(note, user, chunks, content_key, zero) do
    rows = indexed_rows(note)
    merged? = merged_rows?(rows)

    capped =
      if budget_enabled?(),
        do: chunks |> cap_chunks(note_points_cap(user), merged?) |> fit_positions(merged?),
        else: fit_positions(chunks, merged?)

    # As `prepare_index/4` plans it: dense unless the opts say otherwise.
    dense? = Keyword.get(version_rebuild_opts(note), :dense, true)
    plan = plan_chunks(capped, rows, content_key, dense?)

    # C13 averages each member's OWN stored vector: a fingerprint that lives
    # only as a member of a merged point has none, so it is not counted, and
    # a note that never had dense vectors (nil hash) has none at all.
    known =
      if Map.get(note, :dense_indexed_hash) == nil,
        do: MapSet.new(),
        else: standalone_hmacs(rows)

    Enum.reduce(plan.entries, zero, fn entry, acc ->
      chunk = entry_chunk(entry)
      acc = count_length(acc, chunk)

      case entry do
        {:reuse, _chunk, _point_id, _tokens} ->
          %{acc | reused_points: acc.reused_points + 1}

        {:embed, %{merged: true, member_hmacs: hmacs}} when hmacs != [] ->
          if dense_chunk?(chunk, dense?) and Enum.all?(hmacs, &MapSet.member?(known, &1)),
            do: %{acc | mean_pooled_points: acc.mean_pooled_points + 1},
            else: embed_estimate(acc, chunk, dense?)

        {:embed, _chunk} ->
          embed_estimate(acc, chunk, dense?)
      end
    end)
  end

  @doc """
  The opts a version rebuild (`EmbedNote`, `RebuildStaleNote`) indexes a
  content-current note with, shared with `rebuild_estimate/2`: our
  maintenance (unmetered) when the note's dense vectors are for its current
  content, and its dense points are kept.
  """
  @spec version_rebuild_opts(map()) :: keyword()
  def version_rebuild_opts(note) do
    hash = Map.get(note, :content_hash)
    [maintenance: hash != nil and Map.get(note, :dense_indexed_hash) == hash, keep_dense: true]
  end

  defp standalone_hmacs(rows),
    do:
      MapSet.new(
        for {hmac, point_id, _tokens, nil} <- rows,
            hmac != nil and point_id != nil,
            do: short_hmac(hmac)
      )

  defp embed_estimate(acc, chunk, dense?) do
    tokens =
      if dense_chunk?(chunk, dense?),
        do: UsageMeters.estimate_tokens(IO.iodata_length(chunk.embed_text)),
        else: 0

    %{acc | new_points: acc.new_points + 1, est_tokens: acc.est_tokens + tokens}
  end

  # The same raw keyword length `chunks.token_count` stores (`build_entry/3`).
  defp count_length(acc, chunk) do
    if capped_length?(chunk) do
      acc
    else
      text = IO.iodata_to_binary(chunk.context_text)
      {_tokens, len} = Engram.KeywordIndex.Tokenizer.tokens_with_len(text)
      %{acc | dl_sum: acc.dl_sum + len, dl_count: acc.dl_count + 1}
    end
  end

  # Both inputs: `context_text` (keyword vector, payload) and `embed_text`
  # (dense vector). They are capped separately, so past 512 bytes of
  # "folder > title" a title change can leave `context_text` equal while
  # `embed_text` moves. Length-prefixed so the pair cannot be confused.
  defp fingerprint_input(chunk) do
    IO.iodata_to_binary([
      Integer.to_string(IO.iodata_length(chunk.context_text)),
      ":",
      chunk.context_text,
      chunk.embed_text
    ])
  end

  # `/embed_text`: the dense input dropped the folder in chunker v3 (#1621),
  # so a vector fingerprinted before then came from another string.
  # `embed_model/0`, not the configured value alone: with EMBED_MODEL unset the
  # embedder sends its own default, and a reuse fingerprint that names no
  # model would reuse old-model vectors after a default change, under a new
  # model stamp. (Prod sets DOC_EMBED_MODEL, so its model part is unchanged.)
  defp fingerprint_prefix(true), do: "dense:#{pass_model()}/embed_text\n"
  defp fingerprint_prefix(false), do: "sparse\n"

  # `embed_text`, not `context_text`: no folder, which is a filter key, not
  # meaning (#1621). The reuse fingerprint covers both (`fingerprint_input/1`).
  # Only the chunks that get a dense vector: this list is what is reserved,
  # metered and sent to Voyage.
  defp embed_texts(plan),
    do:
      for(
        {:embed, chunk} <- plan.entries,
        sent?(chunk, plan.dense?),
        do: chunk.embed_text
      )

  # One vector per :embed entry, in entry order: the embedder's in turn, nil
  # for a chunk that is sparse-only.
  defp entry_vectors(plan, vectors) do
    {spread, []} =
      Enum.flat_map_reduce(plan.entries, vectors, fn
        {:reuse, _chunk, _point_id, _tokens}, left ->
          {[], left}

        {:embed, %{vector: vector}}, left ->
          {[vector], left}

        {:embed, chunk}, left ->
          if dense_chunk?(chunk, plan.dense?),
            do: {[hd(left)], tl(left)},
            else: {[nil], left}
      end)

    spread
  end

  defp note_language(chunks) do
    chunks
    |> Enum.filter(&(&1.kind == "prose"))
    |> Enum.take(3)
    |> Enum.map_join("\n\n", & &1.text)
    |> detect_language()
  end

  @doc """
  Sparse-only re-index: rebuild the keyword vector of every point this note
  still owns, in place (Qdrant update-vectors). No embedder call, no points
  added or removed, dense vectors and payloads untouched. This is how stored
  keyword vectors follow a tokenizer change without a Voyage bill.

  A chunk is rewritten only if it still matches a stored point by
  fingerprint (dense, sparse-only for points that never had a dense vector,
  or the legacy unprefixed form written before #1606), or, for a row with no
  fingerprint, by position and offsets.

  Returns `{:ok, points_updated, points_unmatched}`. An unmatched point kept
  its old keyword vector: a boundary the current chunker no longer produces
  (a v1 chunk whose blob v2 strips), or a chunk edited since the last index.
  The first carries a stale `chunker_version`, so the chunker rebuild owns
  it; an edited note is EmbedNote's.
  """
  def resparse_note(note, user) do
    chunks = Markdown.parse(note.content || "", note.path)

    if floor_tier(note), do: refloor(note, user, chunks), else: resparse(note, user, chunks)
  end

  # A floor point matches no chunk fingerprint, and on a one-section note it
  # can match chunk 0 by offsets, which would swap the whole-note vector for
  # one chunk's and give the row a length. Rebuild the floor instead: one
  # point, no embedder, same cost class as a resparse.
  defp refloor(_note, _user, []), do: {:ok, 0, 0}

  defp refloor(note, user, chunks) do
    with {:ok, prepared} <- prepare_chunks(note, user, chunks, []),
         {:ok, count} <- commit_index(prepared),
         do: {:ok, count, 0}
  end

  # A merged note is matched and encoded as the merged chunks its points
  # were built from, length-capped, with no lengths written back. Which
  # merge comes from the stored row count, not today's cap: the cap may have
  # moved since (an upgrade or an override), and until the next full pass the
  # points are still the old merge.
  defp resparse(note, user, chunks) do
    with {:ok, content_key} <- Crypto.dek_content_hash_key(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      rows = stored_rows(note)

      chunks =
        (length(rows) < length(chunks) and merged_like(chunks, length(rows))) ||
          chunks

      case match_stored_points(rows, chunks, content_key) do
        {[], unmatched} ->
          {:ok, 0, unmatched}

        {matched, unmatched} ->
          avgdl = avgdl(note.user_id, note.vault_id)
          language = note_language(chunks)
          sparse = encode_sparse(Enum.map(matched, &elem(&1, 0)), filter_key, avgdl, language)

          {points, lengths} =
            Enum.zip_with(matched, sparse, fn {chunk, point_id}, {vector, doc_len} ->
              {%{id: point_id, vector: %{"keyword" => vector}},
               {point_id, if(capped_length?(chunk), do: nil, else: doc_len)}}
            end)
            |> Enum.unzip()

          # A merged point's length stays NULL; only unmerged rows write theirs.
          lengths = Enum.reject(lengths, &is_nil(elem(&1, 1)))

          with :ok <- update_vectors_batched(points),
               :ok <- if(lengths == [], do: :ok, else: persist_token_counts(note, lengths)),
               do: {:ok, length(points), unmatched}
      end
    end
  end

  # `chunks.token_count` is the only input to the vault's `avgdl`, so a
  # resparse that changes what is encoded must move the stored lengths with
  # it, or BM25 normalizes against lengths of a string it no longer encodes.
  # One statement for the whole note.
  defp persist_token_counts(note, lengths) do
    {ids, counts} = Enum.unzip(lengths)
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)

    {:ok, {updated, _}} =
      Repo.with_tenant(note.user_id, fn ->
        Chunk
        |> join(
          :inner,
          [c],
          v in fragment("SELECT * FROM unnest(?::uuid[], ?::int[]) AS v(id, n)", ^ids, ^counts),
          on: c.qdrant_point_id == v.id
        )
        |> where([c], c.note_id == ^note.id)
        |> update([c, v], set: [token_count: v.n])
        |> Repo.update_all([])
      end)

    # Fewer rows than points: a concurrent EmbedNote replaced the note's chunk
    # rows between the match and this update. Its own pass wrote lengths for
    # the new rows, so nothing is lost, but a persistent gap would mean
    # mis-scoped writes; leave a trail rather than fail the job.
    if updated != length(ids) do
      Logger.warning(
        "resparse token_count update matched fewer rows than points",
        Metadata.with_category(:warning, :search,
          note_id: note.id,
          expected: length(ids),
          updated: updated
        )
      )
    end

    :ok
  end

  defp stored_rows(note) do
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Chunk
        |> where([c], c.note_id == ^note.id and not is_nil(c.qdrant_point_id))
        |> select(
          [c],
          {c.context_hmac, c.qdrant_point_id, {c.position, c.char_start, c.char_end}}
        )
        |> Repo.all()
      end)

    rows
  end

  defp match_stored_points(rows, chunks, content_key) do
    by_hmac =
      for({hmac, id, _} <- rows, hmac != nil, do: {hmac, id})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # A row with NO fingerprint (written before context_hmac existed, or
    # cleared by a DEK rotation) still names the chunk it holds by position
    # and offsets. Only those rows match this way: a row WITH a fingerprint
    # that no candidate equals holds other text.
    by_offsets = Map.new(for {nil, id, offsets} <- rows, do: {offsets, id})

    # Third candidate: rows written between #1595 (context_hmac) and #1606
    # (the pass-type prefix) hold an UNPREFIXED hmac of context_text. Reuse
    # must not accept them (they say nothing about which vectors the point
    # holds), but this rewrites only the keyword vector, so the text match is
    # all it needs.
    keyed =
      Enum.zip([
        chunks,
        fingerprints(content_key, chunks, true),
        fingerprints(content_key, chunks, false),
        Engram.Native.hmac_hex_many(
          content_key,
          "",
          Enum.map(chunks, &IO.iodata_to_binary(&1.context_text))
        )
      ])

    {matched, _left} =
      Enum.flat_map_reduce(keyed, {by_hmac, by_offsets}, fn {chunk, dense, sparse, legacy},
                                                            {hmacs, offsets} = acc ->
        offset_key = {chunk.position, chunk.char_start, chunk.char_end}

        case Enum.find([dense, sparse, legacy], &match?([_ | _], Map.get(hmacs, &1))) do
          nil ->
            case Map.pop(offsets, offset_key) do
              {nil, _} -> {[], acc}
              {id, rest} -> {[{chunk, id}], {hmacs, rest}}
            end

          hmac ->
            [id | rest] = Map.fetch!(hmacs, hmac)
            {[{chunk, id}], {Map.put(hmacs, hmac, rest), offsets}}
        end
      end)

    {matched, length(rows) - length(matched)}
  end

  defp update_vectors_batched(points) do
    points
    |> point_batches()
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Qdrant.update_vectors(collection(), Enum.map(batch, &unpack_point/1)) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

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
  defp build_prepared(note, user, plan, vectors, filter_key, avgdl) do
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
    # Keep prose chunks only, rather than trusting position: the frontmatter
    # chunk is appended last today, but a short note can have so few body chunks
    # that a positional take swallows it anyway (a one-section note has exactly
    # two), and data chunks (logs, number tables) can lead the note. A note with
    # no prose then yields no sample and falls back to raw token indexing, which
    # is the right answer: YAML keys or numbers should not pick a stemmer for
    # prose that doesn't exist. A floor plan carries its own (its one chunk has
    # no text to detect from).
    language =
      Map.get_lazy(plan, :language, fn ->
        note_language(Enum.map(plan.entries, &entry_chunk/1))
      end)

    # ONE extraction of the v5 frontmatter filter fields, two sinks: the
    # `note_attrs` rows (the source of truth, written in the chunk-row
    # transaction by `stamp_flat_fields/1`) and, once `:write_v5_layout` is
    # on, the v5 Qdrant payload. User-added keys get their per-user
    # dictionary ids first (allocated here, committed on their own: an id
    # for a key whose pass then fails is harmless). Both behind flags that
    # are off, so with them off a pass does exactly what main does: no
    # extraction, no Postgres writes, the v3 payload.
    # A v5 rebuild writes the v5 layout whatever the flags say: the pass IS
    # the move to it, and it re-extracts the flat fields from the current
    # frontmatter for every note it touches (Task 16.3).
    rebuild? = Map.get(plan, :rebuild?, false)
    v5_format? = rebuild? or Qdrant.v5_payload_format?()
    v5? = rebuild? or write_v5_layout?()

    flat =
      if v5_format?,
        do: note.content |> FlatFields.extract(filter_key) |> with_key_ids(note, user)

    note_payload = if v5?, do: PayloadV5.build(note, flat), else: note_payload(note)
    ctx = {note, user, note_payload, now, v5?}

    point_ids =
      if v5?, do: v5_point_ids(note, plan), else: Enum.map(plan.entries, fn _ -> nil end)

    # The whole note in one call so the encoder can share per-note work (the
    # token -> dim memo) across chunks. One sparse vector per :embed entry, in
    # the same order as `entry_vectors/2`. `context_text`, not `text`: the
    # folder, title and heading path live only in the prefix, and a note with
    # no H1 is otherwise unfindable by its own name on the keyword leg (#1615).
    # `resparse_note/2` must encode the same string.
    #
    # ponytail: a floor plan is the whole note as ONE document, so one NIF call
    # (dirty CPU scheduler) tokenizes all of it, unbounded by `@docs_per_call`.
    # Fine for notes of a few MB; split the text and merge term counts if a
    # floor encode ever shows up as a long dirty-scheduler hold.
    sparse =
      encode_sparse(for({:embed, chunk} <- plan.entries, do: chunk), filter_key, avgdl, language)

    prepared =
      Enum.reduce_while(
        Enum.zip(plan.entries, point_ids),
        {:ok, [], Enum.zip(entry_vectors(plan, vectors), sparse)},
        fn
          {entry, point_id}, {:ok, acc, pending} ->
            case build_entry(entry, {ctx, point_id}, pending) do
              {:ok, built, rest} -> {:cont, {:ok, [built | acc], rest}}
              {:error, _reason} = err -> {:halt, err}
            end
        end
      )

    text? = v5? or chunk_text_write?()

    mode =
      cond do
        not text? -> :none
        display_ct?(note) -> :sealed
        true -> :sum
      end

    with {:ok, reversed, _spent} <- prepared,
         {:ok, dek} <-
           if(v5_format? or mode != :none, do: Crypto.get_dek(user), else: {:ok, nil}) do
      built = Enum.reverse(reversed)
      qdrant_points = for(%{point: p} <- built, p != nil, do: p)

      {:ok,
       %{
         note: note,
         chunk_rows: Enum.map(built, & &1.row),
         point_rows: point_rows(plan.entries, built, dek, mode),
         qdrant_points: qdrant_points,
         point_kinds: for(%{kind: k, dense?: d} <- built, do: {k, d}),
         # Straight from the plan, not re-derived from `built`. Two independent
         # derivations of the same list is how "reused" and "not deleted" drift
         # apart, and the drift is silent: an id in one list but not the other
         # is either a stray or a row pointing at nothing.
         reused_point_ids: plan.reused_point_ids,
         stale_point_ids: unrewritten(plan.stale_point_ids, qdrant_points, v5?),
         note_payload: note_payload,
         payload_hash: payload_hash(note_payload),
         v5_layout?: v5?,
         rebuild?: rebuild?
       }
       |> then(fn p ->
         if v5_format?,
           do: Map.put(p, :attr_rows, FlatFields.attr_rows(flat, note)),
           else: p
       end)}
    end
  end

  # Past the per-user cap a new key is skipped (left out of the payload and
  # `note_attrs`, counted by `FrontmatterKeys`), never an indexing error.
  defp with_key_ids(flat, note, user) do
    case Crypto.get_dek(user) do
      {:ok, dek} ->
        {ids, _skipped} = FrontmatterKeys.resolve(note.user_id, dek, flat.names)
        FlatFields.put_key_ids(flat, ids)

      _no_dek ->
        flat
    end
  end

  # Task 11.2, hybrid (notes-chunks-hyperopt 2.4/2.4b): with text on, every
  # point also gets a `chunk_points` row (written in the same transaction as
  # its `chunks` row, `commit_index/2`) carrying `slice_sum`, the checksum of
  # its chunk's display text; search derives the text from the note content
  # (`display_chunks/3`). Only a note at or over `display_ct_threshold/0` also
  # stores the text and heading, sealed as ONE envelope bound to the point
  # id, so a hit there never decrypts and re-chunks the whole note. A reused
  # point is sealed afresh from the chunk in hand: rows are rewritten
  # wholesale anyway. nil: text off, `chunk_points` untouched.
  defp point_rows(_entries, _built, _dek, :none), do: nil

  defp point_rows(entries, built, dek, mode) do
    ck = Crypto.dek_content_hash_key_from_bytes(dek)

    Enum.zip_with(entries, built, fn entry, %{row: row} ->
      chunk = entry_chunk(entry)

      point = %{
        point_id: row.qdrant_point_id,
        note_id: row.note_id,
        user_id: row.user_id,
        char_start: row.char_start,
        char_end: row.char_end,
        token_count: row.token_count,
        slice_sum: text_sum(ck, chunk.text),
        position: row.position,
        member_fps: member_fps(row.member_hmacs),
        display_ct: nil
      }

      if mode == :sealed, do: Map.merge(point, seal(chunk, dek, row)), else: point
    end)
  end

  # The 16-hex member fingerprint prefixes as 8 raw bytes each, concatenated.
  defp member_fps(nil), do: nil
  defp member_fps(hexes), do: Enum.map_join(hexes, &Base.decode16!(&1, case: :mixed))

  defp seal(chunk, dek, row),
    do: Crypto.encrypt_chunk_text(chunk.text, chunk.heading_path, dek, row.qdrant_point_id)

  # Design owner, 2026-10-21: 32 KB bounds the search re-chunk of one hit
  # note to ~8 ms (~0.19-0.26 ms/KB measured), <= ~0.4 s at limit 50.
  @display_ct_threshold 32 * 1024

  defp display_ct?(note), do: byte_size(note.content || "") >= @display_ct_threshold

  @doc "Notes whose plaintext content is at least this many bytes store each chunk's display envelope."
  def display_ct_threshold, do: @display_ct_threshold

  @doc """
  A chunk's display-text checksum, as a signed int4 for the column: the
  first 4 bytes of HMAC-SHA256 under the user's content-hash subkey
  (`Crypto.dek_content_hash_key/1`, the key of every other fingerprint).
  Keyed, so someone reading the table cannot confirm a guessed short text;
  a DEK rotation re-sums every row (`UserDekRotation`).
  """
  @spec text_sum(binary(), iodata()) :: integer()
  def text_sum(content_key, text) do
    <<sum::signed-32, _rest::binary>> = :crypto.mac(:hmac, :sha256, content_key, text)
    sum
  end

  @doc """
  The chunks search shows for a note, by position: what the indexing pass
  built from this content, for a note holding `row_count` rows. A merged
  note is regrouped the way `resparse_note/2` does (`merged_like/2`, from
  the stored row count). A position missing from the map, or a chunk whose
  `text_sum/2` differs from the row's, means the note changed since it was
  indexed.
  """
  @spec display_chunks(binary(), String.t(), non_neg_integer()) :: %{
          non_neg_integer() => %{text: binary(), heading_path: term()}
        }
  def display_chunks(content, path, row_count) do
    chunks = Markdown.parse(content, path)

    chunks =
      (row_count < length(chunks) and merged_like(chunks, row_count)) || chunks

    Map.new(chunks, &{&1.position, Map.take(&1, [:text, :heading_path])})
  end

  # Off until the v5 rollout turns it on; the v5 layout writes text
  # regardless, since its payload has none.
  defp chunk_text_write?, do: Engram.ServiceConfig.get(:chunk_text_write, false)

  # A reused chunk costs nothing but a row: no embed, no tokenizer pass, no
  # encryption. Its `token_count` rides along from the row it replaces rather
  # than being recomputed from text that has not changed.
  defp build_entry({:reuse, chunk, point_id, tokens}, {{note, _u, _p, now, _v5}, _id}, pending) do
    {:ok, %{row: chunk_row(note, chunk, point_id, tokens, now), point: nil}, pending}
  end

  # `doc_len` is the raw token count from the same tokenization pass as the
  # sparse vector, also persisted as `chunks.token_count`.
  defp build_entry({:embed, chunk}, {ctx, v5_id}, [{vector, {sparse, doc_len}} | rest]) do
    {note, user, note_payload, now, v5?} = ctx
    point_id = v5_id || Ecto.UUID.generate()

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

    # A v5 point carries filter fields and ids only: its text, title and
    # heading live in Postgres (Task 11), so there is nothing to encrypt.
    encrypted =
      if v5?,
        do: {:ok, note_payload},
        else: Crypto.encrypt_qdrant_payload(base_payload, user, collection(), point_id)

    case encrypted do
      {:ok, payload} ->
        # Omit the dense named vector entirely when there is none — Qdrant
        # rejects a null vector, and a partial named-vector upsert is the
        # supported way to store sparse-only points.
        named_vectors =
          case vector do
            nil -> %{"keyword" => sparse}
            v -> %{"dense" => v, "keyword" => sparse}
          end

        # A floor or merged row's length stays out of `avgdl` (see
        # `floor_plan/2`, `cap_chunks/3`).
        token_count = if capped_length?(chunk), do: nil, else: doc_len

        built = %{
          row: chunk_row(note, chunk, point_id, token_count, now),
          point: %{id: point_id, vector: named_vectors, payload: payload},
          kind: metric_kind(note.path, chunk.kind),
          dense?: vector != nil
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

  # Canvas and base chunks are "data" to the chunker; the metric wants them
  # apart so each embed-less lever can be sized on its own. Closed enum.
  defp metric_kind(path, kind) do
    case Path.extname(path) do
      ".canvas" -> "canvas"
      ".base" -> "base"
      _ when kind == "frontmatter_dense" -> "frontmatter"
      _ when kind in ~w(prose data frontmatter drawing) -> kind
      _ -> "prose"
    end
  end

  defp chunk_row(note, chunk, point_id, token_count, now) do
    %{
      note_id: note.id,
      user_id: note.user_id,
      vault_id: note.vault_id,
      position: chunk.position,
      # No heading_path: the heading ("Title > H1 > H2") is note content and
      # lives encrypted in the Qdrant payload, which is where search reads it.
      # The Postgres column was nulled by the 20260926 migrate-data migration
      # and is dropped by the next contract release.
      char_start: chunk.char_start,
      char_end: chunk.char_end,
      token_count: token_count,
      qdrant_point_id: point_id,
      context_hmac: chunk.context_hmac,
      member_hmacs: Map.get(chunk, :member_hmacs),
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
  @doc false
  # The legacy note-level payload, for DEK rotation's filter-key resync.
  def legacy_note_payload(note), do: note_payload(note)

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

  # Deterministic ids for the :embed entries (nil for :reuse), in entry order.
  # Reuse matches by fingerprint, not by ordinal, so a reused point can
  # already hold `v5(F, k)` for the k an embed would get (review M7: two rows
  # naming one point). An id taken by a reused point, or earlier in this
  # pass, moves to the next free ordinal, which is still deterministic for
  # the same rows and content.
  defp v5_point_ids(note, plan) do
    taken = MapSet.new(plan.reused_point_ids)
    fps = Enum.map(plan.entries, &entry_chunk(&1).context_hmac)

    {ids, _} =
      plan.entries
      |> Enum.zip(PointId.ordinals(fps))
      |> Enum.map_reduce(taken, fn
        {{:reuse, _c, _id, _t}, _ord}, taken ->
          {nil, taken}

        {{:embed, chunk}, ord}, taken ->
          id = PointId.free_v5(note.id, chunk.context_hmac, ord, taken)
          {id, MapSet.put(taken, id)}
      end)

    ids
  end

  # v5 points are REPLACED, not merged: their payload omits absent and default
  # keys, so a merge would keep a removed key (or an old folder id) forever.
  defp refresh_payload(%{v5_layout?: true}, ids, payload),
    do: Qdrant.overwrite_payload(collection(), ids, payload)

  defp refresh_payload(_prepared, ids, payload),
    do: Qdrant.set_payload(collection(), ids, payload)

  # UUIDv5 ids and the text-free payload (Task 15.1/15.3), off until PR-17:
  # until then every write keeps random ids and payload text.
  defp write_v5_layout?, do: Qdrant.write_v5_layout?()

  # A deterministic id can equal a stale id of the previous pass (same
  # fingerprint and ordinal, not reused because the plan regrouped). The point
  # was just rewritten, so deleting it as stale would delete the new point.
  defp unrewritten(stale, _points, false), do: stale

  defp unrewritten(stale, points, true) do
    written = MapSet.new(points, & &1.id)
    Enum.reject(stale, &MapSet.member?(written, &1))
  end

  # Inside the chunk-row transaction, from the same extraction as the payload.
  # The note's rows are replaced wholesale, like the chunk rows, so an absent
  # key leaves no row.
  defp stamp_flat_fields(%{note: note, attr_rows: rows}) do
    :ok = hold_key_ids!(note, rows)

    {_n, old} =
      Repo.delete_all(
        from(a in NoteAttr,
          where: a.note_id == ^note.id,
          select: {a.key_id, a.ord, a.h, a.n, a.d}
        )
      )

    _ = rows |> Enum.chunk_every(@insert_batch) |> Enum.each(&Repo.insert_all(NoteAttr, &1))

    # The field catalog is cached on change_seq, which this pass does not
    # move, so a pass that changed the rows evicts it (after this transaction
    # commits). Most re-index passes leave the frontmatter alone: no eviction,
    # no cluster broadcast.
    if MapSet.new(old) != MapSet.new(rows, &{&1.key_id, &1.ord, &1.h, &1.n, &1.d}),
      do: FieldCatalog.evict(note.vault_id),
      else: :ok
  end

  defp stamp_flat_fields(_prepared), do: :ok

  # The user-key ids this pass writes were resolved before the Voyage call, so
  # the daily reaper may have deleted one since (a key back after a day with no
  # note using it). FOR KEY SHARE holds every one until commit, which blocks
  # the reaper's FOR UPDATE; if one is already gone the pass rolls back and
  # `index_note_with_usage/4` re-resolves once (new id, never the dead one).
  defp hold_key_ids!(note, rows) do
    ids = for(%{key_id: id} <- rows, id >= FrontmatterKeys.first_user_id(), do: id) |> Enum.uniq()

    held =
      if ids == [],
        do: [],
        else:
          Repo.all(
            from(k in Engram.Notes.FrontmatterKey,
              where: k.user_id == ^note.user_id and k.key_id in ^ids,
              # One lock order everywhere, so two lockers never deadlock.
              order_by: k.key_id,
              select: k.key_id,
              lock: "FOR KEY SHARE"
            )
          )

    if length(held) < length(ids), do: Repo.rollback(:frontmatter_keys_gone), else: :ok
  end

  # Plaintext inputs, not the stored payload: nothing here is encrypted, but
  # comparing what we would write against a stamp avoids reading Qdrant back.
  # `:deterministic` so equal maps hash equal; an OTP change that alters the
  # encoding costs one extra refresh per note, nothing worse.
  defp payload_hash(note_payload),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(note_payload, [:deterministic]))

  # Encodes a Phase B HMAC binary as base64 for JSON-safe Qdrant payload.
  # Returns nil for nil — leaves the field absent so legacy/un-backfilled
  # rows don't poison filters with a fake hmac.
  defp encode_hmac(nil), do: nil
  defp encode_hmac(bin) when is_binary(bin), do: Base.encode64(bin)

  defp detect_language(text), do: Engram.KeywordIndex.LangDetect.detect(text)
end
