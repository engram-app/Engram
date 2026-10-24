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
  alias Engram.Search.FieldFilters
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
  Notes similar to a stored note, from that note's chunk points (`point_ids`)
  via Qdrant recommend. Same vault guard, entitlement, filters and grouping as
  `search/4`, but NO `ai_searches_per_day` spend: that budget meters the query
  embed, and this path makes none. Results are grouped per note.
  """
  def similar(user, vault, point_ids, opts \\ []) when is_list(point_ids) and point_ids != [] do
    with :ok <- vault_ids_present?(vault, opts),
         :ok <- cross_vault_entitlement(user, opts) do
      do_search_instrumented(
        user,
        vault,
        {:similar, point_ids},
        Keyword.merge(opts, mode: :similar, group_by_note: true)
      )
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
         :ok <- validate_input(query, opts),
         :ok <- cross_vault_entitlement(user, opts),
         {:ok, opts} <- resolve_field_filters(user, opts),
         :ok <- spend_search_budget(user, opts) do
      do_search_instrumented(user, vault, query, opts)
    end
  end

  # `:fields` (frontmatter key filters) resolve to Qdrant conditions ONCE per
  # request, before the budget is spent: an unknown key is an explicit error,
  # never an empty result, and so is asking before the v5 layout can answer
  # (`Engram.Search.FieldFilters`).
  defp resolve_field_filters(user, opts) do
    case Keyword.get(opts, :fields, []) do
      [] ->
        {:ok, opts}

      fields ->
        with true <- FieldFilters.available?() || {:error, :field_filters_unavailable},
             {:ok, fk} <- field_filter_key(user, fields),
             {:ok, conditions} <- FieldFilters.to_conditions(to_string(user.id), fk, fields) do
          {:ok, Keyword.put(opts, :attr_filters, conditions)}
        end
    end
  end

  # A user with no DEK has written no keys, so every key is unknown to them.
  # Any other key error (KMS, unwrap) passes through as itself.
  defp field_filter_key(user, [first | _]) do
    case Engram.Crypto.dek_filter_key(user) do
      {:ok, fk} -> {:ok, fk}
      {:error, :no_dek} -> {:error, {:unknown_field, field_name(first)}}
      {:error, _} = error -> error
    end
  end

  defp field_name(%{} = f),
    do: String.slice(to_string(f["key"] || f[:key]), 0, FieldFilters.max_echo())

  defp field_name(other), do: String.slice(inspect(other), 0, FieldFilters.max_echo())

  # Voyage's context window is 32k tokens and a token is at least one byte,
  # so a query this size always fits, with room. Real queries are far
  # shorter; one this long is a pasted document.
  @max_query_bytes 8_192

  @doc "The longest query, in bytes, `search/4` accepts."
  def max_query_bytes, do: @max_query_bytes

  @doc """
  Refuses a search input that a downstream service would refuse later,
  before the search is billed:

    * `{:error, :query_too_long}` past `max_query_bytes/0`. The query embed
      runs with `truncation: false`, so Voyage would 400 and the search lose
      its dense leg;
    * `{:error, :too_many_tags}` past `Qdrant.max_ids/0` tags (one
      `match.any` condition; Qdrant Cloud's strict `condition_max_size`
      400s a bigger one).
  """
  @spec validate_input(term(), keyword()) :: :ok | {:error, :query_too_long | :too_many_tags}
  def validate_input(query, opts) do
    max_ids = Engram.Vector.Qdrant.max_ids()

    cond do
      is_binary(query) and byte_size(query) > @max_query_bytes -> {:error, :query_too_long}
      too_many?(Keyword.get(opts, :tags), max_ids) -> {:error, :too_many_tags}
      true -> :ok
    end
  end

  defp too_many?(tags, max) when is_list(tags), do: length(tags) > max
  defp too_many?(_tags, _max), do: false

  @doc """
  The caller-facing message for a `validate_input/2` refusal, `nil` for any
  other reason. `param` names the caller's field the query came from
  (MCP `suggest_folder` passes its `description`).
  """
  @spec input_error_message(term(), String.t()) :: String.t() | nil
  def input_error_message(reason, param \\ "query")

  def input_error_message(:query_too_long, param),
    do: "#{param}: at most #{@max_query_bytes} bytes; use a shorter #{param}"

  def input_error_message(:too_many_tags, _param),
    do: "tags: at most #{Engram.Vector.Qdrant.max_ids()} per search"

  def input_error_message(:field_filters_unavailable, _param),
    do: "fields: field filters are not available yet"

  def input_error_message({:unknown_field, key}, _param),
    do: "fields: no note in this account has the frontmatter key #{inspect(key)}"

  def input_error_message({:field_not_indexed, key}, _param),
    do:
      "fields: #{inspect(key)} is not indexed (this account reached its field limit, " <>
        "so new frontmatter keys are not filterable)"

  def input_error_message({:reserved_field, key}, _param),
    do: "fields: #{inspect(key)} is not filterable"

  def input_error_message({:invalid_field_filter, key}, _param),
    do:
      "fields: invalid filter on #{inspect(key)}; use {key, op, value} with op " <>
        "eq, in (a list of at most 100), gt, gte, lt, lte, after or before"

  def input_error_message({:too_many_field_filters, max}, _param),
    do: "fields: at most #{max} field filters per search"

  def input_error_message(_reason, _param), do: nil

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
      |> window_texts(query)

    emit_search_performed(user, result, started_at, cross_vault, surface_prop(opts))

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

  defp window_texts({:ok, results}, query) when is_list(results),
    do: {:ok, results |> collapse_floor_hits() |> Enum.map(&window_text(&1, query))}

  defp window_texts(other, _query), do: other

  @doc """
  Keeps only the first (best ranked) floor hit of each note. A floor point
  has no display text, and a large floored note holds one per MiB, so it
  could fill the results with empty snippets (review M3). Other hits, and
  their order, are untouched.
  """
  def collapse_floor_hits(results) do
    {kept, _seen} =
      Enum.flat_map_reduce(results, MapSet.new(), fn
        %{text: ""} = hit, seen ->
          key = {Map.get(hit, :vault_id), Map.get(hit, :source_path)}
          if MapSet.member?(seen, key), do: {[], seen}, else: {[hit], MapSet.put(seen, key)}

        hit, seen ->
          {[hit], seen}
      end)

    kept
  end

  defp window_text(%{text: text} = result, query) when is_binary(text),
    do: %{result | text: snippet(text, query)}

  defp window_text(result, _query), do: result

  # The chunker caps a chunk's text at 2,048 bytes, so a longer hit text is a
  # merged chunk (several chunks in one point under the per-note cap, up to
  # ~30 KB). Reranking saw all of it; what leaves Search is a window.
  @chunk_text_max 2_048
  @snippet_chars 1_500
  # Context kept ahead of the first match.
  @snippet_lead 200

  @doc """
  A hit's display text. An ordinary chunk's comes back whole. A merged
  chunk's (over 2,048 bytes) is a window of at most 1,500 characters: from
  just before the run of query-word matches (case-insensitive) that holds
  the most distinct query words, or with no match, or a non-text query (a
  similar-notes search), its first 1,500 characters.
  """
  def snippet(text, query) when byte_size(text) > @chunk_text_max do
    case best_match(text, query) do
      nil ->
        String.slice(text, 0, @snippet_chars)

      byte ->
        at = text |> binary_part(0, byte) |> String.length()
        start = max(0, min(at - @snippet_lead, String.length(text) - @snippet_chars))
        String.slice(text, start, @snippet_chars)
    end
  end

  def snippet(text, _query), do: text

  # Byte offset of the first match in the window (`@snippet_chars -
  # @snippet_lead` bytes) holding the most distinct query words; nil when
  # none occurs. One pass over the sorted matches with a trailing pointer, so
  # a common word matching thousands of times stays linear. Byte widths stand
  # in for character widths, which only skews the choice on multi-byte text.
  defp best_match(text, query) when is_binary(query) do
    hits =
      query
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.uniq()
      |> Enum.flat_map(fn word ->
        for [{at, _len}] <-
              Regex.scan(Regex.compile!(Regex.escape(word), "iu"), text, return: :index),
            do: {at, word}
      end)
      |> Enum.sort()

    case hits do
      [] -> nil
      _ -> densest_window(List.to_tuple(hits), @snippet_chars - @snippet_lead)
    end
  end

  defp best_match(_text, _query), do: nil

  # Window [hits[i], hits[i] + width): `j` is one past its last hit, `counts`
  # its words. Returns the offset of the best window's first hit.
  defp densest_window(hits, width) do
    n = tuple_size(hits)

    {_j, _counts, {_best, at}} =
      Enum.reduce(0..(n - 1), {0, %{}, {0, nil}}, fn i, {j, counts, best} ->
        {start, _} = elem(hits, i)
        {j, counts} = extend(hits, n, j, counts, start + width)
        best = if map_size(counts) > elem(best, 0), do: {map_size(counts), start}, else: best
        {_, word} = elem(hits, i)
        {j, drop_word(counts, word), best}
      end)

    at
  end

  defp extend(hits, n, j, counts, limit) do
    case j < n and elem(hits, j) do
      {at, word} when at < limit ->
        extend(hits, n, j + 1, Map.update(counts, word, 1, &(&1 + 1)), limit)

      _ ->
        {j, counts}
    end
  end

  defp drop_word(counts, word) do
    case Map.fetch!(counts, word) do
      1 -> Map.delete(counts, word)
      c -> Map.put(counts, word, c - 1)
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

  defp emit_search_performed(user, {:ok, results}, started_at, cross_vault, surface)
       when is_list(results) do
    latency_ms = System.monotonic_time(:millisecond) - started_at

    Engram.Analytics.track(
      user,
      "search_performed",
      Map.merge(surface, %{
        status: "ok",
        result_count: length(results),
        latency_ms: latency_ms,
        cross_vault: cross_vault
      })
    )
  end

  defp emit_search_performed(_user, _other, _started_at, _cross_vault, _surface), do: :ok

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
  Maps a caller-supplied mode string to a search mode (unknown → `:hybrid`).

  The REST `mode` param and the MCP `mode` tool arg are the same closed enum, so
  the mapping lives here rather than once per transport.
  """
  @spec parse_mode(term()) :: :keyword | :vector | :hybrid
  def parse_mode("keyword"), do: :keyword
  def parse_mode("vector"), do: :vector
  def parse_mode(_), do: :hybrid

  # The opt key IS the request param name, so one list serves both transports.
  # Order is the order REST validates them in.
  @date_params [:created_after, :created_before, :updated_after, :updated_before]

  # No @spec: `[atom()]` is a supertype of the literal list's success typing and
  # dialyzer runs with `:underspecs`. See `Engram.OAuth.Client`'s note on the
  # same trade for its constant accessors.
  @doc "The date-bound opt keys `search/4` accepts (also their param names)."
  def date_params, do: @date_params

  defp do_search(user, vault, query, opts) do
    # Hybrid, not dense-only, when the caller names no mode (MCP's
    # `suggest_folder` and note auto-placement). A note indexed while its
    # owner's embed budget was spent has only the sparse leg, so a dense-only
    # default cannot find it. Hybrid reaches both, and already degrades to
    # keyword when the query embed fails.
    mode = Keyword.get(opts, :mode, :hybrid)
    limit = opts |> Keyword.get(:limit, 5) |> clamp_limit()
    tags = opts |> Keyword.get(:tags) |> tag_filter()
    folder = Keyword.get(opts, :folder)
    type = Keyword.get(opts, :type)
    date_bounds = date_bound_kw(opts)

    # On the grouped path `limit` is the NOTE count, not the chunk count.
    group? = Keyword.get(opts, :group_by_note, false)
    profile = SearchProfile.resolve(user)
    # Caller `:diversity` opt overrides the profile default; nil → profile
    # default. Clamped to [0.0, 1.0]. diversity > 0 ⇒ MMR pass ⇒ the pool
    # query brings the dense vectors back with it (one call).
    diversity = clamp_diversity(Keyword.get(opts, :diversity), profile.diversity)
    diversify? = diversity > 0.0

    # Over-fetch a candidate pool whenever we'll rerank (per-plan) OR diversify,
    # so MMR has more than `limit` to choose from. `candidate_pool` defaults to
    # 20 via the profile (SearchProfile.@default_pool).
    pool = max(limit * 4, profile.candidate_pool)
    # Grouped path ALWAYS over-fetches the pool: grouping needs more than
    # `note_limit` chunks to populate `note_limit` notes, and the full pool must
    # also survive the reranker so collapse_to_notes sees every candidate (even
    # at diversity 0, where it must not be starved down to `limit` chunks).
    # A similar_to query is `{:similar, ids}`, not text: nothing to rerank against.
    rerank_for_user? = reranker_active?() and profile.reranker and is_binary(query)
    fetch_limit = if group? or rerank_for_user? or diversify?, do: pool, else: limit
    # Keep the whole pool through the reranker when diversifying or grouping so
    # MMR / collapse can see it; otherwise the reranker cuts straight to `limit`
    # (unchanged chunk-path behavior).
    rerank_keep = if group? or diversify?, do: pool, else: limit

    read? = chunk_text_read?()

    case translate_phase_b_filters(user, folder, tags, type) do
      {:ok, phase_b_kw} ->
        search_opts =
          [user_id: to_string(user.id), limit: fetch_limit]
          |> then(&put_vault_filter(&1, vault, opts))
          |> Keyword.merge(phase_b_kw)
          |> Keyword.merge(date_bounds)
          |> Keyword.put(:attr_filters, Keyword.get(opts, :attr_filters, []))
          |> Keyword.put(:with_vector, diversify?)
          |> Keyword.put(:full_precision, profile.full_precision)
          |> Keyword.put(:chunk_text_read, read?)
          |> Keyword.put(:tenant_idf, mode in [:keyword, :hybrid] and tenant_idf?(user))

        with {:ok, candidates} <- run_legs(mode, user, query, search_opts, profile),
             {:ok, {candidates, hits}} <- postgres_hits(candidates, user, read?),
             {:ok, candidates} <- payload_fallback(candidates, hits, user),
             vaults_by_id = load_candidate_vaults(user, vault, candidates),
             {:ok, decrypted} <- decrypt_candidates(candidates, user, vaults_by_id, hits) do
          rerank_module = if rerank_for_user?, do: reranker(), else: Engram.Rerankers.None

          with {:ok, ranked} <- rerank_module.rerank(query, decrypted, rerank_keep) do
            ranked |> rehydrate_display_fields(user, hits) |> diversify(group?, limit, diversity)
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

  # The page from the rehydrated pool. Rehydrate comes first: a soft-deleted
  # hit is dropped while the pool can still backfill its slot (dropping after
  # left a page short of `limit`, #1608), and collapse_to_notes keys on the
  # decrypted source_path. Grouped, diversity runs at note granularity.
  defp diversify(live, true = _group?, limit, diversity) do
    notes = collapse_to_notes(live)

    if diversity > 0.0,
      do: {:ok, MMR.rerank(notes, limit, diversity)},
      else: {:ok, notes |> Enum.sort_by(& &1.score, :desc) |> Enum.take(limit)}
  end

  defp diversify(live, false, limit, diversity), do: {:ok, MMR.rerank(live, limit, diversity)}

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

  # similar_to: the source note's stored dense vectors, averaged by Qdrant.
  defp run_legs(:similar, _user, {:similar, point_ids}, search_opts, _profile),
    do: Qdrant.recommend(collection(), point_ids, search_opts)

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

  @doc """
  Whether the keyword leg computes IDF over this user's points only (spec
  K4). Off unless `:tenant_idf` is set (default false, `TENANT_IDF`; it
  changes keyword ranking, so it is flipped at v5 go time). Then: Qdrant
  >= 1.19.0 (older servers reject the param) and at least
  `ServiceConfig.get(:tenant_idf_min_points, 1_000)` points, below which a
  per-tenant N is noise.

  Neither input is read per search. The version is cached 5 minutes,
  unreadable included (as unknown, so < 1.19, with one warning per probe);
  the count 10 minutes per user. A failed count falls back to global IDF.
  """
  @spec tenant_idf?(map()) :: boolean()
  def tenant_idf?(user) do
    Engram.ServiceConfig.get(:tenant_idf, false) == true and
      tenant_idf_version?() and
      tenant_points(user) >= Engram.ServiceConfig.get(:tenant_idf_min_points, 1_000)
  end

  defp tenant_idf_version? do
    version =
      Engram.Cache.fetch(:tenant_idf_version, Qdrant.base_url(), fn ->
        case Qdrant.cached_server_version() do
          %Version{} = v ->
            v

          nil ->
            Logger.warning("tenant idf: qdrant version unknown, using global idf")
            :unknown
        end
      end)

    match?(%Version{}, version) and Version.compare(version, "1.19.0") != :lt
  end

  # ponytail: nothing evicts this on re-index; the count only feeds a
  # threshold, so up to 10 minutes stale is fine. Evict from the indexing
  # commit if the threshold ever needs to be exact.
  defp tenant_points(user) do
    Engram.Cache.fetch(:tenant_points, user.id, fn ->
      Engram.Indexing.point_count(user.id)
    end)
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error, MatchError] ->
      Logger.warning("tenant idf: point count failed, using global idf",
        reason: Metadata.safe_reason(e)
      )

      0
  end

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

  # No tags named is no tag filter: MCP clients send `"tags": []`, and REST
  # `tags[]=` decodes as `[""]`. Left in, either matched nothing.
  defp tag_filter(tags) when is_list(tags) do
    case Enum.reject(tags, &(&1 == "")) do
      [] -> nil
      named -> named
    end
  end

  defp tag_filter(tags), do: tags

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

  # Task 11.3: off until the v5 rollout; off, search reads exactly as before.
  # Read ONCE per request (`do_search/4`) and carried in the search opts, so
  # the Qdrant key list and how the hits are read never disagree mid-flip.
  defp chunk_text_read?, do: Qdrant.chunk_text_read?()

  # With `:chunk_text_read` on: ONE query for every candidate's chunk row
  # (vault, text, heading) and note display fields, keyed by point id. The
  # vault comes from the row, not the payload (Task 15.7: Qdrant no longer
  # returns `vault_id`).
  #
  # - No row: a stale point. Qdrant is written before the rows commit, so
  #   every edit opens a short window, and a crash leaves one until
  #   OrphanSweep reaps it. Dropped and counted (`no_chunk_row`), debug log.
  # - Soft-deleted note: dropped (#1608), as rehydrate does.
  # - Text or note row that does not decrypt: dropped and counted under its
  #   own reason. If that leaves nothing, the search fails `:decrypt_failed`
  #   (a DEK or KMS outage), as the payload decrypt always has, rather than
  #   answering an empty page.
  defp postgres_hits(candidates, _user, false), do: {:ok, {candidates, nil}}

  defp postgres_hits(candidates, user, true) do
    ids = Enum.map(candidates, & &1[:qdrant_id])
    # The denominator of the hits_dropped / text_missing ratio alert.
    :telemetry.execute([:engram, :search, :hits], %{count: length(ids)}, %{})

    with {:ok, hits} <- Engram.Notes.search_hits_by_qdrant_points(user, ids) do
      {kept, dropped} =
        Enum.reduce(candidates, {[], %{}}, fn c, {kept, dropped} ->
          case Map.get(hits, c[:qdrant_id]) do
            %{vault_id: vault_id} -> {[Map.put(c, :vault_id, vault_id) | kept], dropped}
            nil -> {kept, bump(dropped, :no_chunk_row)}
            :deleted -> {kept, dropped}
            undecryptable -> {kept, bump(dropped, undecryptable)}
          end
        end)

      for {reason, count} <- dropped, do: emit_hit_dropped(reason, count, user)

      undecryptable? =
        Map.has_key?(dropped, :text_undecryptable) or Map.has_key?(dropped, :note_undecryptable)

      if kept == [] and undecryptable?,
        do: {:error, :decrypt_failed},
        else: {:ok, {Enum.reverse(kept), hits}}
    end
  end

  defp bump(counts, reason), do: Map.update(counts, reason, 1, &(&1 + 1))

  # With `:chunk_text_read` on the ranked query fetches no payload; the hits
  # whose chunk row has no text (rows written before the text columns) get
  # their payload text keys here, in one retrieve of just those points (none
  # when every row has its text). A point deleted since the query is dropped
  # and counted (`point_gone`), as main never returned it. A failed retrieve
  # fails the search, as a failed query does.
  defp payload_fallback(candidates, nil, _user), do: {:ok, candidates}

  defp payload_fallback(candidates, hits, user) do
    case for(c <- candidates, is_nil(hits[c.qdrant_id].text), do: c.qdrant_id) do
      [] -> {:ok, candidates}
      ids -> merge_fallback(candidates, ids, user)
    end
  end

  defp merge_fallback(candidates, ids, user) do
    keys = Qdrant.result_payload(:fallback)

    with {:ok, points} <- Qdrant.retrieve(collection(), ids, with_payload: keys) do
      by_id = Map.new(points, &{&1.qdrant_id, &1})
      wanted = MapSet.new(ids)

      {gone, kept} =
        Enum.split_with(
          candidates,
          &(&1.qdrant_id in wanted and not is_map_key(by_id, &1.qdrant_id))
        )

      if gone != [], do: emit_hit_dropped(:point_gone, length(gone), user)
      {:ok, Enum.map(kept, &Map.merge(Map.get(by_id, &1.qdrant_id, %{}), &1))}
    end
  end

  # One counter for every reason (`engram_prom_ex_search_hits_dropped_total`).
  # The orphan windows (a stale point, a point deleted mid-search) are
  # expected on every edit, so they log at debug; the others are real faults.
  defp emit_hit_dropped(reason, count, user) do
    :telemetry.execute([:engram, :search, :hit_dropped], %{count: count}, %{reason: reason})

    meta =
      Metadata.with_category(:warning, :search, user_id: user.id, reason: reason, count: count)

    case reason do
      :no_chunk_row -> Logger.debug("search dropped #{count} hit(s): no chunk row", meta)
      :point_gone -> Logger.debug("search dropped #{count} hit(s): point gone", meta)
      _ -> Logger.warning("search dropped #{count} hit(s): #{reason}", meta)
    end
  end

  defp decrypt_candidates(candidates, user, vaults_by_id, nil),
    do: Engram.Crypto.decrypt_qdrant_candidates(candidates, user, vaults_by_id, collection())

  # Postgres text first; a row written before the text columns falls back to
  # the payload (v3/v4 points); a row with neither keeps its hit, with empty
  # text, counted as `text_missing` (the title and path still show).
  #
  # The vault check the payload decrypt applies (`decrypt_one/4`) applies
  # here first, to every hit: a hit whose row vault is not an active vault of
  # this search (soft-deleted, or not asked for) is dropped (`vault_inactive`).
  defp decrypt_candidates(candidates, user, vaults_by_id, hits) do
    {candidates, inactive} = Enum.split_with(candidates, &Map.has_key?(vaults_by_id, &1.vault_id))
    if inactive != [], do: emit_hit_dropped(:vault_inactive, length(inactive), user)

    {from_payload, rest} =
      Enum.split_with(
        candidates,
        &(is_nil(hits[&1.qdrant_id].text) and Map.has_key?(&1, :text_nonce))
      )

    payload =
      Engram.Crypto.decrypt_qdrant_candidates(from_payload, user, vaults_by_id, collection())

    by_id =
      case payload do
        {:ok, decrypted} -> Map.new(decrypted, &{&1.qdrant_id, &1})
        {:error, _} -> %{}
      end

    # A fallback hit the payload decrypt did not return is gone from the
    # page, whether the whole batch errored or one point failed.
    lost = length(from_payload) - map_size(by_id)
    if lost > 0, do: emit_hit_dropped(:payload_undecryptable, lost, user)

    missing = Enum.count(rest, &is_nil(hits[&1.qdrant_id].text))

    if missing > 0,
      do: :telemetry.execute([:engram, :search, :text_missing], %{count: missing}, %{})

    result =
      Enum.flat_map(candidates, fn c ->
        case hits[c.qdrant_id] do
          %{text: nil} when is_map_key(c, :text_nonce) ->
            List.wrap(by_id[c.qdrant_id])

          %{text: text, heading_path: heading} ->
            [
              c
              |> Map.drop([:title, :text_nonce, :title_nonce, :heading_path_nonce])
              |> Map.merge(%{text: text || "", heading_path: heading})
            ]
        end
      end)

    case {result, payload} do
      {[], {:error, _} = err} -> err
      _ -> {:ok, result}
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
  # them, and the title, on the final (post-rerank) result set from the
  # encrypted `notes` rows, keyed by qdrant_point_id. The title in the payload
  # goes stale on rename (repath patches only the HMACs), so the row wins. Candidates whose note row is missing keep
  # whatever the payload provided (nil), rather than dropping the hit. A hit
  # whose note is soft-deleted IS dropped: its points outlive the delete until
  # DeleteNoteIndex succeeds, and they must not answer searches meanwhile
  # (#1608).
  #
  # With `:chunk_text_read` on, the fields were already loaded with the text
  # (`postgres_hits/2`), so this is a lookup, not a second query.
  defp rehydrate_display_fields([], _user, _hits), do: []

  defp rehydrate_display_fields(results, user, nil) do
    qdrant_ids =
      results |> Enum.map(&Map.get(&1, :qdrant_id)) |> Enum.reject(&is_nil/1)

    apply_display_fields(results, Engram.Notes.display_fields_by_qdrant_points(user, qdrant_ids))
  end

  defp rehydrate_display_fields(results, _user, hits), do: apply_display_fields(results, hits)

  defp apply_display_fields(results, fields_by_qid) do
    Enum.flat_map(results, fn result ->
      case Map.get(fields_by_qid, Map.get(result, :qdrant_id)) do
        %{source_path: source_path, title: title, tags: tags} ->
          [
            result
            |> Map.put(:source_path, source_path)
            |> Map.put(:title, title)
            |> Map.put(:tags, tags)
          ]

        :deleted ->
          []

        nil ->
          [result]
      end
    end)
  end

  @doc false
  # Collapse ranked chunks to one representative per {vault_id, source_path}.
  # The representative carries the highest-scoring chunk's score/vector/display
  # fields; match_count is the number of chunks for that note in the input.
  #
  # A chunk with no source_path is dropped: rehydrate found no chunk row for
  # its point. Expected briefly after a write, because commit_index upserts
  # Qdrant BEFORE inserting the rows (so a failure leaves reapable stray points,
  # never a row naming a missing point). One event per search with the count,
  # so a window that stops being brief shows up on a dashboard instead of as
  # silently missing results.
  def collapse_to_notes(chunks) do
    {orphans, live} = Enum.split_with(chunks, &is_nil(Map.get(&1, :source_path)))

    if orphans != [] do
      :telemetry.execute(
        [:engram, :search, :hit_dropped],
        %{count: length(orphans)},
        %{reason: :no_chunk_row}
      )
    end

    live
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
        vector: note_vector(group, best),
        match_count: length(group)
      }
    end)
  end

  # The note's direction for the diversity pass: its best chunk's vector, or
  # its best dense chunk's when the best hit is sparse-only (frontmatter, data).
  defp note_vector(group, best) do
    case Map.get(best, :vector) do
      nil ->
        group
        |> Enum.filter(&Map.get(&1, :vector))
        |> Enum.max_by(& &1.score, fn -> %{} end)
        |> Map.get(:vector)

      vector ->
        vector
    end
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
  defp spend_search_budget(user, opts) do
    case Billing.cap(user, :ai_searches_per_day) do
      nil ->
        :ok

      limit when is_integer(limit) and limit > 0 ->
        case RateLimiter.hit("ai_search:#{user.id}", @budget_scale_ms, limit, :ai_search) do
          {:allow, _count} -> :ok
          {:deny, _retry} -> refuse_search(user, limit, opts)
        end

      # `Billing.cap/2` answers `integer | nil` and maps every "no cap" spelling
      # (including a malformed override) to nil, so what reaches here is an
      # integer <= 0: a tier configured not to search at all.
      limit ->
        refuse_search(user, limit, opts)
    end
  end

  # Reported here, at the one funnel, so MCP refusals count as well as REST.
  # Throttled like `limit_hit` (one per user and surface per hour): a client
  # retrying past its cap must not send one event per retry.
  defp refuse_search(user, limit, opts) do
    surface = surface_prop(opts)
    Engram.Analytics.track_limit_hit(user, :ai_searches_per_day, surface)

    Engram.Analytics.track_throttled(
      user,
      "search_performed",
      "refused:#{Map.get(surface, :surface, "unknown")}",
      :timer.hours(1),
      Map.put(surface, :status, "refused")
    )

    {:error, :search_cap_exceeded, limit}
  end

  # The transport that searched (`web`, `api`, `obsidian_sync`, `mcp`), passed
  # by the caller as `opts[:surface]`. Omitted when the caller did not say.
  defp surface_prop(opts) do
    case Keyword.get(opts, :surface) do
      surface when is_binary(surface) -> %{surface: surface}
      _ -> %{}
    end
  end
end
