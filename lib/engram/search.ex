defmodule Engram.Search do
  @moduledoc """
  Two-stage search: embed query → Qdrant similarity (4x candidates) →
  reranker (blend scores) → return top N results.

  Both embedder and reranker are config-driven behaviours:
  - `:embedder`  — Engram.Embedders.Voyage | .Ollama | any Engram.Embedder impl
  - `:reranker`  — Engram.Rerankers.Jina | .None | any Engram.Reranker impl
  """

  alias Engram.KeywordIndex
  alias Engram.Notes.Helpers
  alias Engram.Search.MMR
  alias Engram.Search.SearchProfile
  alias Engram.Vector.Qdrant

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "obsidian_notes")

  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  defp reranker, do: Application.get_env(:engram, :reranker, Engram.Rerankers.None)

  defp reranker_active?, do: reranker() != Engram.Rerankers.None

  defp query_embed_model, do: Application.get_env(:engram, :query_embed_model)

  defp embed_for_search(query, model) do
    # `purpose: :query` routes through a separate Voyage rate-limit bucket
    # so a bulk indexing burst can't starve synchronous user search. `model`
    # comes from the per-user SearchProfile; nil falls back to the global
    # query-embed model (or the embedder default when that too is unset).
    case model || query_embed_model() do
      nil -> embedder().embed_texts([query], purpose: :query)
      m -> embedder().embed_texts([query], model: m, purpose: :query)
    end
  end

  @doc """
  Search notes for a user within a vault. Returns {:ok, results} where each result has:
  score, text, title, heading_path, source_path, tags.

  Pass `vault: nil` with `cross_vault: true` in opts to search across all user vaults
  (requires billing feature check).

  Options:
  - `:limit`       — number of results (default 5)
  - `:tags`        — filter to notes with any of these tags
  - `:folder`      — filter to notes in this folder
  - `:cross_vault` — when true, search across all vaults (billing-gated)
  """
  def search(user, vault, query, opts \\ []) do
    cross_vault = Keyword.get(opts, :cross_vault, false)
    started_at = System.monotonic_time(:millisecond)

    # engram-app/engram-infra#340 — emit
    # [:engram, :search, :request, :start/:stop] for the PromEx Search plugin.
    # Hand-rolled (not `:telemetry.span/3`) so result_count is a measurement
    # — `:telemetry.span` only allows extra metadata, not measurements.
    # Cardinality contract: no user_id, vault_id, or query string.
    rerank = rerank_label(user)
    start_mono = System.monotonic_time()
    start_meta = %{cross_vault: cross_vault, rerank: rerank}

    :telemetry.execute(
      [:engram, :search, :request, :start],
      %{system_time: System.system_time(), monotonic_time: start_mono},
      start_meta
    )

    result =
      if cross_vault do
        case Engram.Billing.check_feature(user, :cross_vault_search) do
          :ok -> do_search(user, nil, query, opts)
          {:error, _} = err -> err
        end
      else
        do_search(user, vault, query, opts)
      end
      |> scrub_result_utf8()

    emit_search_performed(user, result, started_at, cross_vault)

    :telemetry.execute(
      [:engram, :search, :request, :stop],
      %{
        duration: System.monotonic_time() - start_mono,
        result_count: result_count(result)
      },
      %{
        status: search_status(result),
        cross_vault: cross_vault,
        rerank: rerank
      }
    )

    result
  end

  # Defensive: legacy notes may already hold invalid UTF-8 (stored before the
  # upsert-time scrub). Returning it raises Jason at the JSON boundary (a 500 for
  # MCP `search_notes` and the web `/api/search`), so guarantee valid UTF-8 in
  # every string field before results leave Search.
  @scrubbed_string_keys [:text, :title, :heading_path, :source_path]

  defp scrub_result_utf8({:ok, results}) when is_list(results),
    do: {:ok, Enum.map(results, &scrub_result_fields/1)}

  defp scrub_result_utf8(other), do: other

  defp scrub_result_fields(result) when is_map(result) do
    result =
      Enum.reduce(@scrubbed_string_keys, result, fn key, acc ->
        case Map.get(acc, key) do
          v when is_binary(v) -> Map.put(acc, key, Helpers.scrub_utf8(v, :search))
          _ -> acc
        end
      end)

    case Map.get(result, :tags) do
      tags when is_list(tags) ->
        Map.put(
          result,
          :tags,
          Enum.map(tags, &if(is_binary(&1), do: Helpers.scrub_utf8(&1, :search), else: &1))
        )

      _ ->
        result
    end
  end

  defp search_status({:ok, _}), do: :ok
  defp search_status({:error, _}), do: :error

  defp result_count({:ok, results}) when is_list(results), do: length(results)
  defp result_count(_), do: 0

  defp rerank_label(user) do
    case Engram.Billing.check_feature(user, :reranker_enabled) do
      :ok -> if reranker_active?(), do: :on, else: :off
      {:error, _} -> :off
    end
  end

  defp emit_search_performed(user, {:ok, results}, started_at, cross_vault)
       when is_list(results) do
    latency_ms = System.monotonic_time(:millisecond) - started_at

    Engram.Observability.PostHog.capture(
      Engram.Observability.PostHog.distinct_id_for(user),
      "search_performed",
      %{
        result_count: length(results),
        latency_ms: latency_ms,
        cross_vault: cross_vault
      }
    )
  end

  defp emit_search_performed(_user, _other, _started_at, _cross_vault), do: :ok

  defp do_search(user, vault, query, opts) do
    mode = Keyword.get(opts, :mode, :vector)
    limit = Keyword.get(opts, :limit, 5)
    tags = Keyword.get(opts, :tags)
    folder = Keyword.get(opts, :folder)

    # On the grouped path `limit` is the NOTE count, not the chunk count.
    group? = Keyword.get(opts, :group_by_note, false)
    profile = SearchProfile.resolve(user)
    # Caller `:diversity` opt overrides the profile default; nil → profile
    # default. Clamped to [0.0, 1.0]. diversity > 0 ⇒ MMR pass ⇒ we need the
    # dense vectors back from Qdrant.
    diversity = clamp_diversity(Keyword.get(opts, :diversity), profile.diversity)
    need_vectors? = diversity > 0.0

    # Over-fetch a candidate pool whenever we'll rerank (per-plan) OR diversify,
    # so MMR has more than `limit` to choose from. `candidate_pool` defaults to
    # 20 via the profile (SearchProfile.@default_pool).
    pool = max(limit * 4, profile.candidate_pool)
    rerank_for_user? = reranker_active?() and profile.reranker
    # Grouped path ALWAYS over-fetches the pool: grouping needs more than
    # `note_limit` chunks to populate `note_limit` notes, and the full pool must
    # also survive the reranker so collapse_to_notes sees every candidate (even
    # at diversity 0, where it must not be starved down to `limit` chunks).
    fetch_limit = if group? or rerank_for_user? or need_vectors?, do: pool, else: limit
    # Keep the whole pool through the reranker when diversifying or grouping so
    # MMR / collapse can see it; otherwise the reranker cuts straight to `limit`
    # (unchanged chunk-path behavior).
    rerank_keep = if group? or need_vectors?, do: pool, else: limit

    case translate_phase_b_filters(user, folder, tags) do
      {:ok, phase_b_kw} ->
        search_opts =
          [user_id: to_string(user.id), limit: fetch_limit]
          |> then(&if(vault, do: Keyword.put(&1, :vault_id, to_string(vault.id)), else: &1))
          |> Keyword.merge(phase_b_kw)
          |> Keyword.put(:with_vector, need_vectors?)
          |> Keyword.put(:full_precision, profile.full_precision)

        with {:ok, candidates} <- run_legs(mode, user, query, search_opts, profile),
             vaults_by_id = load_candidate_vaults(user, vault, candidates),
             {:ok, decrypted} <-
               Engram.Crypto.decrypt_qdrant_candidates(
                 candidates,
                 user,
                 vaults_by_id,
                 collection()
               ) do
          rerank_module = if rerank_for_user?, do: reranker(), else: Engram.Rerankers.None

          with {:ok, ranked} <- rerank_module.rerank(query, decrypted, rerank_keep) do
            if group? do
              # Rehydrate the WHOLE pool BEFORE grouping — collapse_to_notes keys
              # on the decrypted source_path, so it must be filled in first. Then
              # diversify at note granularity.
              notes = collapse_to_notes(rehydrate_display_fields(ranked, user))

              final =
                if need_vectors? do
                  MMR.rerank(notes, limit, diversity)
                else
                  notes |> Enum.sort_by(& &1.score, :desc) |> Enum.take(limit)
                end

              {:ok, final}
            else
              diversified = MMR.rerank(ranked, limit, diversity)
              {:ok, rehydrate_display_fields(diversified, user)}
            end
          end
        end

      :no_dek_with_filter ->
        # Caller asked to filter by folder/tags but has no DEK provisioned —
        # impossible to derive HMAC, and the user has no encrypted points to
        # match anyway. Mirrors list_folders (B.2.2) defensive empty.
        {:ok, []}
    end
  end

  # nil → use the profile default; a number is clamped to [0.0, 1.0] and forced
  # to a float (MMR's diversity==0.0 short-circuit relies on a float compare);
  # anything else (defensive) → 0.0 (no diversity).
  defp clamp_diversity(nil, default), do: clamp_diversity(default, 0.0)

  defp clamp_diversity(v, _default) when is_number(v),
    do: v |> max(0.0) |> min(1.0) |> :erlang.float()

  defp clamp_diversity(_other, _default), do: 0.0

  # Vector leg: embed query → dense Qdrant search (existing behavior preserved).
  defp run_legs(:vector, _user, query, search_opts, profile) do
    with {:ok, [vector]} <- embed_for_search(query, profile.query_model) do
      Qdrant.search(collection(), vector, search_opts)
    end
  end

  # Keyword leg: HMAC the query tokens → sparse Qdrant search. No DEK → empty.
  defp run_legs(:keyword, user, query, search_opts, _profile) do
    case sparse_query(user, query) do
      {:ok, sparse} -> Qdrant.sparse_search(collection(), sparse, search_opts)
      :no_vault -> {:ok, []}
    end
  end

  # Hybrid: dense + sparse fused server-side. No-DEK or empty-query degrades to
  # vector-only. Embedding failure (backend down/rate-limited) degrades to
  # keyword-only rather than failing a search the keyword leg could still serve.
  defp run_legs(:hybrid, user, query, search_opts, profile) do
    case embed_for_search(query, profile.query_model) do
      {:ok, [vector]} ->
        case sparse_query(user, query) do
          {:ok, sparse} -> Qdrant.hybrid_search(collection(), vector, sparse, search_opts)
          :no_vault -> Qdrant.search(collection(), vector, search_opts)
        end

      {:error, _reason} = err ->
        # Embedding backend down/rate-limited: degrade to keyword-only rather
        # than failing a search the keyword leg could still serve.
        case sparse_query(user, query) do
          {:ok, sparse} -> Qdrant.sparse_search(collection(), sparse, search_opts)
          :no_vault -> err
        end
    end
  end

  defp sparse_query(user, query) do
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        case KeywordIndex.module().encode_query(query, filter_key) do
          %{indices: []} -> :no_vault
          sparse -> {:ok, sparse}
        end

      {:error, :no_dek} ->
        :no_vault
    end
  end

  # Returns either {:ok, kw} where kw is the [folder_hmac: ..., tags_hmac: ...]
  # subset to merge into Qdrant search opts, or :no_dek_with_filter when the
  # caller asked for a filter but has no DEK to derive the HMAC. An unfiltered
  # search (no folder, no tags) is always {:ok, []} — DEK not required.
  defp translate_phase_b_filters(_user, nil, nil), do: {:ok, []}

  defp translate_phase_b_filters(user, folder, tags) do
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        kw =
          []
          |> maybe_put_folder_hmac(filter_key, folder)
          |> maybe_put_tags_hmac(filter_key, tags)

        {:ok, kw}

      {:error, :no_dek} ->
        :no_dek_with_filter
    end
  end

  defp maybe_put_folder_hmac(kw, _filter_key, nil), do: kw

  defp maybe_put_folder_hmac(kw, filter_key, folder),
    do: Keyword.put(kw, :folder_hmac, Base.encode64(Engram.Crypto.hmac_field(filter_key, folder)))

  defp maybe_put_tags_hmac(kw, _filter_key, nil), do: kw

  defp maybe_put_tags_hmac(kw, filter_key, tags) do
    encoded = Enum.map(tags, &Base.encode64(Engram.Crypto.hmac_field(filter_key, &1)))
    Keyword.put(kw, :tags_hmac, encoded)
  end

  # Single-vault search: return the passed-in vault directly — no extra DB query.
  # Cross-vault search (vault=nil): batch-load only the vaults referenced by candidates.
  defp load_candidate_vaults(_user, %Engram.Vaults.Vault{id: id} = v, _candidates),
    do: %{to_string(id) => v}

  defp load_candidate_vaults(user, nil, candidates) do
    vault_ids =
      candidates
      |> Enum.map(&Map.get(&1, :vault_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Engram.Vaults.list_for_ids(user, vault_ids)
  end

  # #590: Qdrant payloads no longer carry plaintext source_path/tags. Refill
  # them on the final (post-rerank) result set from the encrypted `notes`
  # rows, keyed by qdrant_point_id. Candidates whose note row is missing keep
  # whatever the payload provided (nil), rather than dropping the hit.
  defp rehydrate_display_fields([], _user), do: []

  defp rehydrate_display_fields(results, user) do
    qdrant_ids =
      results |> Enum.map(&Map.get(&1, :qdrant_id)) |> Enum.reject(&is_nil/1)

    fields_by_qid = Engram.Notes.display_fields_by_qdrant_points(user, qdrant_ids)

    Enum.map(results, fn result ->
      case Map.get(fields_by_qid, Map.get(result, :qdrant_id)) do
        %{source_path: source_path, tags: tags} ->
          result |> Map.put(:source_path, source_path) |> Map.put(:tags, tags)

        nil ->
          result
      end
    end)
  end

  @doc false
  # Collapse ranked chunks to one representative per {vault_id, source_path}.
  # The representative carries the highest-scoring chunk's score/vector/display
  # fields; match_count is the number of chunks for that note in the input.
  def collapse_to_notes(chunks) do
    chunks
    |> Enum.reject(&is_nil(Map.get(&1, :source_path)))
    |> Enum.group_by(&{Map.get(&1, :vault_id), Map.fetch!(&1, :source_path)})
    |> Enum.map(fn {{vault_id, path}, group} ->
      best = Enum.max_by(group, & &1.score)

      %{
        source_path: path,
        vault_id: vault_id,
        title: Map.get(best, :title),
        heading_path: Map.get(best, :heading_path),
        text: Map.get(best, :text),
        score: best.score,
        vector: Map.get(best, :vector),
        match_count: length(group)
      }
    end)
  end
end
