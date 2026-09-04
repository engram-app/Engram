defmodule Engram.Search do
  @moduledoc """
  Two-stage search: embed query → Qdrant similarity (4x candidates) →
  reranker (blend scores) → return top N results.

  Both embedder and reranker are config-driven behaviours:
  - `:embedder`  — Engram.Embedders.Voyage | .Ollama | any Engram.Embedder impl
  - `:reranker`  — Engram.Rerankers.Jina | .None | any Engram.Reranker impl
  """

  alias Engram.Billing
  alias Engram.KeywordIndex
  alias Engram.Logger.Metadata
  alias Engram.Notes.Helpers
  alias Engram.Search.MMR
  alias Engram.Search.SearchProfile
  alias Engram.Vector.Qdrant
  alias EngramWeb.RateLimiter

  require Logger

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
  - `:type`: filters to notes whose OKF frontmatter `type` matches (HMAC'd)
  - `:created_after`/`:created_before`: filters to OKF `created` DateTime bounds
  - `:updated_after`/`:updated_before`: filters to OKF `timestamp` DateTime bounds
  - `:cross_vault` — when true, search across all vaults (billing-gated)
  """
  def search(user, vault, query, opts \\ []) do
    # Entitlement BEFORE budget, and both ahead of the telemetry span.
    #
    # Order is load-bearing: a cross-vault search the user is not entitled to is
    # refused for a DIFFERENT reason, so charging a token for it bills them for
    # a search they never got. Unreachable on stock tiers today (Free caps
    # `vaults_cap` at 1, and Starter — the tier with vaults but no cross-vault —
    # has no search cap), but a per-user override on either key makes it live.
    #
    # Ahead of the span because a refused search never ran: counting it in the
    # duration / result-count histograms would skew both.
    #
    # `vault_ids_present?` is ahead of everything else: `vault_ids: []` means
    # the caller's credential can reach zero vaults, and the one thing that
    # must never happen is treating that as "no filter" and running an
    # unfiltered cross-vault search (#729). Refuse before billing/budget even
    # look at the request, and long before a Qdrant query could be built.
    with :ok <- vault_ids_present?(vault, opts),
         :ok <- cross_vault_entitlement(user, opts),
         :ok <- spend_search_budget(user) do
      do_search_instrumented(user, vault, query, opts)
    end
  end

  # Fail closed: an explicit empty `vault_ids` means the credential's accessible
  # set is empty, so refuse rather than let it fall through to unfiltered
  # cross-vault (#729). `vault_ids` omitted entirely keeps its existing,
  # unrelated meaning — only the explicit empty-list case is refused.
  #
  # Keyed on whether the search will EFFECTIVELY run cross-vault, not on `vault`
  # being nil: `do_search_instrumented/4` nils the vault LATER when
  # `cross_vault: true`, so the REST path — which always passes the concrete
  # vault VaultPlug resolved — walked straight past the earlier `nil`-only
  # clause, i.e. the guard was bypassed on exactly the path it was written for.
  #
  # Truthiness rather than `== true`: `SearchController` reads `cross_vault`
  # straight off request params, so `?cross_vault=true` arrives as the STRING
  # "true". Every other reader of the opt (`cross_vault_entitlement/2`,
  # `do_search_instrumented/4`) is a bare `if`, so matching on the boolean here
  # would make this guard the one place that disagrees about what cross-vault
  # means.
  defp vault_ids_present?(vault, opts) do
    cross_vault? = is_nil(vault) or !!Keyword.get(opts, :cross_vault, false)

    case {cross_vault?, Keyword.get(opts, :vault_ids)} do
      {true, []} -> {:error, :no_accessible_vaults}
      _ -> :ok
    end
  end

  defp cross_vault_entitlement(user, opts) do
    if Keyword.get(opts, :cross_vault, false) do
      cross_vault_allowed(user, opts)
    else
      :ok
    end
  end

  defp do_search_instrumented(user, vault, query, opts) do
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

    # Entitlement is already checked in `search/4`, ahead of the budget spend —
    # `cross_vault` here only selects the nil vault filter.
    result =
      if cross_vault do
        do_search(user, nil, query, opts)
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

  # Cross-vault is a Pro billing feature on the web/API path. The MCP server
  # makes multi-vault search the default for every tier (product decision
  # 2026-07-10), so it passes `allow_cross_vault: true` to bypass the gate.
  # The MCP caller is responsible for narrowing to the credential's ACCESSIBLE
  # set — either by passing a concrete `vault` or, for a subset, by passing
  # `vault_ids`, which becomes an any-match Qdrant filter. Neither widens
  # beyond what the caller may see.
  defp cross_vault_allowed(user, opts) do
    if Keyword.get(opts, :allow_cross_vault, false) do
      :ok
    else
      Engram.Billing.check_feature(user, :cross_vault_search)
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

  # Context-boundary bound on the caller-supplied limit: the controller
  # clamps to 50, but MCP/console callers hit this module directly and
  # `limit` drives a 4x candidate-pool over-fetch into Qdrant.
  @max_context_limit 100

  @doc """
  Clamps a caller-supplied result limit to 1..#{@max_context_limit}.
  """
  @spec clamp_limit(integer()) :: pos_integer()
  def clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_context_limit)

  @doc """
  Clamps a caller-requested search mode to what the user is entitled to.

  A user without `search_semantic_enabled` gets `:keyword` no matter what was
  asked for — an explicit `?mode=vector`, an MCP tool arg, or the `:vector`
  default all collapse to keyword-only. Pure so the gate is testable without
  Qdrant.

  Typed `term() -> term()` on purpose. `:mode` is caller-supplied external
  input, so an unrecognised value has to pass through to `run_legs/5`'s
  invalid-mode clause and become `{:error, :invalid_mode}`. Narrowing this spec
  to the three valid atoms lets dialyzer prove that clause unreachable, which
  deletes the guard protecting us from a bad MCP arg.
  """
  @spec effective_mode(term(), SearchProfile.t()) :: term()
  def effective_mode(_requested, %SearchProfile{semantic: false}), do: :keyword
  def effective_mode(requested, %SearchProfile{}), do: requested

  defp do_search(user, vault, query, opts) do
    requested_mode = Keyword.get(opts, :mode, :vector)
    limit = opts |> Keyword.get(:limit, 5) |> clamp_limit()
    tags = Keyword.get(opts, :tags)
    folder = Keyword.get(opts, :folder)
    type = Keyword.get(opts, :type)
    date_bounds = date_bound_kw(opts)

    # On the grouped path `limit` is the NOTE count, not the chunk count.
    group? = Keyword.get(opts, :group_by_note, false)
    profile = SearchProfile.resolve(user)
    # Entitlement gate lives HERE, not in the controller: MCP calls
    # Search.search/4 directly and two of its call sites pass no mode at all.
    mode = effective_mode(requested_mode, profile)
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

    case translate_phase_b_filters(user, folder, tags, type) do
      {:ok, phase_b_kw} ->
        search_opts =
          [user_id: to_string(user.id), limit: fetch_limit]
          |> then(&put_vault_filter(&1, vault, opts))
          |> Keyword.merge(phase_b_kw)
          |> Keyword.merge(date_bounds)
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
        # Caller asked to filter by folder/tags/type but has no DEK
        # provisioned, so it's impossible to derive HMAC, and the user has no
        # encrypted points to match anyway. Mirrors list_folders (B.2.2)
        # defensive empty.
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

      {:error, reason} = err ->
        # Embedding backend down/rate-limited: degrade to keyword-only rather
        # than failing a search the keyword leg could still serve.
        #
        # Emit ONLY on the arm that actually degrades. When sparse_query/2
        # returns :no_vault the search hard-FAILS — signalling "degraded to
        # keyword-only" there would conflate real fallbacks with outright
        # failures in engram_prom_ex_search_degraded_total, and show an operator
        # a "degraded" line in Loki for a request that returned an error.
        case sparse_query(user, query) do
          {:ok, sparse} ->
            # This MUST be loud. Degradation is silent by construction — the
            # caller gets a normal 200 with plausible results — so without a
            # signal an operator whose Ollama is slow or down just gets quietly
            # worse search forever, and in CI the vector leg can vanish
            # suite-wide without a single line in the log. A test asserting
            # semantic behaviour would then pass on the sparse leg and look like
            # proof.
            #
            # Log the BOUNDED label, not the raw reason: on the {status, body}
            # branch that body is the decoded provider response — unbounded and
            # unreviewed — and this ships to Loki + CloudWatch on every degraded
            # search. Leaking it would undercut the point of HMAC'ing folders and
            # tags to keep content out of third-party stores.
            Logger.warning(
              "Search degraded to keyword-only — query embed failed",
              Metadata.with_category(:warning, :search,
                user_id: to_string(user.id),
                reason_label: :embed_failed_degraded_to_keyword,
                reason: error_label(reason)
              )
            )

            :telemetry.execute(
              [:engram, :search, :degraded],
              %{count: 1},
              %{leg: :keyword, reason: error_label(reason)}
            )

            Qdrant.sparse_search(collection(), sparse, search_opts)

          :no_vault ->
            err
        end
    end
  end

  # Caller-supplied :mode is external input (MCP/API) — an unknown mode must
  # return an error tuple, not raise FunctionClauseError mid-pipeline.
  defp run_legs(_invalid_mode, _user, _query, _search_opts, _profile),
    do: {:error, :invalid_mode}

  # Bounded label for telemetry AND for the degradation log — the raw reason can
  # carry a whole provider response body, and metric tags must stay
  # low-cardinality (see the Search PromEx contract).
  #
  # Transport reasons are NOT always atoms: Mint/Req surface TLS failures as
  # tuples like `{:tls_alert, {:handshake_failure, ~c"..."}}`, and interpolating
  # one raises `Protocol.UndefinedError` (no String.Chars for tuples). That would
  # crash inside the degrade branch and 500 the request — the error handler added
  # to make degradation observable would be the thing defeating degradation. So
  # atoms only for the readable label; anything else collapses to a constant.
  defp error_label(%Req.TransportError{reason: r}) when is_atom(r), do: "transport_#{r}"
  defp error_label(%Req.TransportError{}), do: "transport_other"
  defp error_label({status, _body}) when is_integer(status), do: "http_#{status}"
  defp error_label(reason) when is_atom(reason), do: to_string(reason)
  defp error_label(_), do: "unknown"

  defp sparse_query(user, query) do
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        language = detect_query_language(query)

        case KeywordIndex.module().encode_query(query, filter_key, language) do
          %{indices: []} -> :no_vault
          sparse -> {:ok, sparse}
        end

      {:error, :no_dek} ->
        :no_vault
    end
  end

  defp detect_query_language(query), do: Engram.KeywordIndex.LangDetect.detect(query) || :en

  # Returns either {:ok, kw} where kw is the [folder_hmac: ..., tags_hmac: ...,
  # type_hmac: ...] subset to merge into Qdrant search opts, or
  # :no_dek_with_filter when the caller asked for a filter but has no DEK to
  # derive the HMAC. An unfiltered search (no folder, no tags, no type) is
  # always {:ok, []}, no DEK required.
  defp translate_phase_b_filters(_user, nil, nil, nil), do: {:ok, []}

  defp translate_phase_b_filters(user, folder, tags, type) do
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, filter_key} ->
        kw =
          []
          |> maybe_put_folder_hmac(filter_key, folder)
          |> maybe_put_tags_hmac(filter_key, tags)
          |> maybe_put_type_hmac(filter_key, type)

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

  defp maybe_put_type_hmac(kw, _filter_key, nil), do: kw

  defp maybe_put_type_hmac(kw, filter_key, type) do
    normalized = Engram.Notes.OkfFields.normalize_type(type)
    Keyword.put(kw, :type_hmac, Base.encode64(Engram.Crypto.hmac_field(filter_key, normalized)))
  end

  # Plaintext date bounds need no DEK; translated straight to unix seconds
  # and merged into search_opts regardless of DEK availability (unlike
  # folder/tags/type, which require a DEK to derive an HMAC).
  defp date_bound_kw(opts) do
    [
      fm_timestamp_gte: opts[:updated_after],
      fm_timestamp_lte: opts[:updated_before],
      fm_created_gte: opts[:created_after],
      fm_created_lte: opts[:created_before]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, %DateTime{} = dt} -> {k, DateTime.to_unix(dt)} end)
  end

  # A concrete vault narrows to one id; `vault_ids` narrows to a set (a
  # multi-vault OAuth grant or a subset-restricted API key); neither means an
  # unfiltered cross-vault search over everything the user owns.
  #
  # Fail-closed note: an empty `vault_ids` list never reaches this function —
  # `search/4`'s `vault_ids_present?` guard refuses the request before
  # `do_search_instrumented`/`do_search` runs, so no Qdrant query is ever
  # built for it. The `ids != []` clause below is what's left over from that
  # guard (a non-empty list narrows; anything else — including omitted
  # `vault_ids` — keeps the existing unfiltered cross-vault behavior), not a
  # second place that decides "empty means unfiltered."
  defp put_vault_filter(search_opts, %Engram.Vaults.Vault{} = vault, _opts),
    do: Keyword.put(search_opts, :vault_id, to_string(vault.id))

  defp put_vault_filter(search_opts, nil, opts) do
    case Keyword.get(opts, :vault_ids) do
      ids when is_list(ids) and ids != [] ->
        Keyword.put(search_opts, :vault_id, Enum.map(ids, &to_string/1))

      _ ->
        search_opts
    end
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

  # THE metering point for `ai_searches_per_day`: at the cost site, not at each
  # transport. `search/4` is the single funnel every retrieval passes through
  # and the Voyage embed happens inside it, so a new caller inherits metering
  # instead of needing to be added to a list. Charging per-transport against a
  # hand-maintained list is exactly how the old cap went unenforced on all of
  # MCP (#1527).
  #
  # There is NO exemption. `MCP.Handlers.auto_place_folder/4` runs a retrieval
  # incidental to a write and is charged like any other — same Voyage embed,
  # same Qdrant query — but it DEGRADES on a refusal (drops the note in the
  # default folder) rather than failing the create. Degrading is the caller's
  # job; not charging would make the write path an unmetered search channel.
  #
  # One day, in milliseconds — the Hammer scale for the search budget.
  @budget_scale_ms 86_400_000

  # Spends one unit of the user's `ai_searches_per_day` budget.
  #
  # Counted in `EngramWeb.RateLimiter`, the SAME cluster-synced ETS counter the
  # rate limiter uses — a daily budget is a rate limit with a 24-hour scale, so
  # it needs no storage layer of its own. In SaaS prod that routes to the
  # `:distributed_ets` backend (per-node ETS + `Phoenix.PubSub` broadcast);
  # self-host falls back to plain per-node ETS. Either way the request path
  # touches no database: this runs on every search, in front of a Voyage embed,
  # and microseconds is the right budget for it.
  #
  # The previous design spent a Postgres token bucket (`Engram.Usage.DailyCap`
  # + the `usage_buckets` table), which was exact across nodes and durable
  # across deploys but cost a round trip on every allowed search. Traded away
  # deliberately: the counter now resets when a node restarts, and a rolling
  # deploy hands users a fresh budget because `DistributedETS` has no state
  # handoff ("new nodes start empty" — see its moduledoc). At ~14 deploys a
  # month that is the accepted charity case, and it matches the limiter's
  # standing principle that every failure biases permissive.
  #
  # Fixed window, not a rolling bucket: Hammer keys buckets by
  # `div(now, scale)`, so the 24-hour window is epoch-aligned and a user can
  # spend the budget either side of a boundary. Same permissive bias.
  defp spend_search_budget(user) do
    case Billing.cap(user, :ai_searches_per_day) do
      nil ->
        :ok

      limit when is_integer(limit) and limit > 0 ->
        case RateLimiter.hit("ai_search:#{user.id}", @budget_scale_ms, limit, :ai_search) do
          {:allow, _count} -> :ok
          {:deny, _retry} -> {:error, :search_cap_exceeded, limit}
        end

      # `Billing.cap/2` answers `integer | nil` and maps every "no cap" spelling
      # (including a malformed override) to nil, so what reaches here is an
      # integer <= 0: a tier configured not to search at all.
      limit ->
        {:error, :search_cap_exceeded, limit}
    end
  end
end
