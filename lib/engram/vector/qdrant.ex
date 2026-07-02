defmodule Engram.Vector.Qdrant do
  @moduledoc """
  Thin Req-based HTTP wrapper for the Qdrant REST API.
  All operations target a single collection.

  Config:
  - :qdrant_url — base URL (default http://localhost:6333)
  - QDRANT_API_KEY env var — API key for Qdrant Cloud (optional for local)
  """

  alias Engram.ServiceConfig

  @default_url "http://localhost:6333"
  @default_collection "obsidian_notes"

  # Payload fields every tenant-scoped op filters on. Qdrant Cloud strict-mode
  # rejects (400) a filter on an un-indexed field, so each must have a keyword
  # index before any upsert/search/delete. `note_id` is not a live filter key
  # today (deletes resolve via `path_hmac`) but is indexed to match the prod
  # collection + future-proof. See #626.
  @payload_index_fields ~w(user_id vault_id note_id path_hmac)

  defp base_url, do: ServiceConfig.get(:qdrant_url, @default_url)
  defp collection, do: ServiceConfig.get(:qdrant_collection, @default_collection)

  @doc "Returns the configured Qdrant collection name (env-var-driven)."
  def collection_name, do: collection()

  defp binary_quantization_enabled?,
    do: ServiceConfig.get(:qdrant_binary_quantization, true)

  # Wrap an HTTP call in a `:telemetry.span` so the PromEx Qdrant plugin
  # (engram-app/engram-infra#340) sees per-op latency + status. `op` is
  # a bounded atom (`:search`, `:upsert`, etc.); status is derived from
  # the result tuple. NEVER include collection name, point ids, or
  # user/vault context — cardinality contract.
  defp instrument(op, fun) when is_atom(op) and is_function(fun, 0) do
    :telemetry.span([:engram, :qdrant, :request], %{op: op}, fn ->
      result = fun.()
      {result, %{op: op, status: qdrant_status(result)}}
    end)
  end

  defp qdrant_status(:ok), do: :ok
  defp qdrant_status({:ok, _}), do: :ok
  defp qdrant_status({:error, _}), do: :error

  # Per-purpose Req options. `:indexing` (default) is patient — 30s timeout +
  # transient retries; callers are Oban workers where an in-call retry is
  # cheaper than burning a job attempt. `:search` backs the synchronous
  # `/api/search` request path and must fail fast: with the indexing opts a
  # Qdrant brownout pins each request up to ~2min (30s x 4 attempts), holding
  # Bandit processes and cascading into pool pressure. Same split the Voyage
  # embedder already has (`request_defaults(:query)` = 5s, no retry).
  @doc false
  def req_opts(purpose \\ :indexing)

  def req_opts(:search) do
    put_api_key(
      receive_timeout: 5_000,
      retry: false,
      max_retries: 0,
      connect_options: [protocols: [:http1]]
    )
  end

  def req_opts(:indexing) do
    {retry, max_retries} =
      case ServiceConfig.get(:qdrant_retry, :transient) do
        false -> {false, 0}
        mode -> {mode, 3}
      end

    put_api_key(
      receive_timeout: 30_000,
      retry: retry,
      max_retries: max_retries,
      retry_log_level: :warning,
      connect_options: [protocols: [:http1]]
    )
  end

  defp put_api_key(base) do
    case ServiceConfig.get(:qdrant_api_key) do
      nil -> base
      key -> Keyword.put(base, :headers, [{"api-key", key}])
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Ensure a collection exists with the given vector dimensions.
  Creates it if missing; no-ops if already present (Qdrant returns 200 either way).

  On a fresh create, also creates the keyword payload indexes every
  tenant-scoped filter depends on (#626). An existing collection already
  carries them (indexes persist), so the steady-state path skips the work —
  the only way to lose them is a drop+recreate, which re-enters the create
  branch.
  """
  def ensure_collection(col \\ nil, dims) do
    col = col || collection()

    case create_collection(col, dims) do
      {:ok, :created} -> ensure_payload_indexes(col)
      {:ok, :exists} -> :ok
      {:error, _} = error -> error
    end
  end

  defp create_collection(col, dims) do
    dense = %{size: dims, distance: "Cosine"}

    body =
      %{
        vectors: %{"dense" => dense},
        sparse_vectors: %{"keyword" => %{modifier: "idf"}}
      }
      |> then(fn b ->
        if binary_quantization_enabled?() do
          Map.put(b, :quantization_config, %{binary: %{always_ram: true}})
        else
          b
        end
      end)

    opts = [json: body] ++ req_opts()

    instrument(:ensure_collection, fn ->
      case Req.put("#{base_url()}/collections/#{col}", opts) do
        {:ok, %{status: status}} when status in [200, 201] -> {:ok, :created}
        {:ok, %{status: 409}} -> existing_collection(col)
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # 409 means the collection already exists. Confirm its shape is compatible
  # and report `:exists` so the caller skips (re-)creating payload indexes,
  # which an existing collection already carries.
  defp existing_collection(col) do
    with :ok <- verify_collection_shape(col), do: {:ok, :exists}
  end

  # Create a keyword payload index per filtered field, right after a fresh
  # collection create. `?wait=true` blocks until each index is ready so the
  # first upsert can't race an unbuilt index. Stops at the first failure so a
  # real error surfaces.
  defp ensure_payload_indexes(col) do
    Enum.reduce_while(@payload_index_fields, :ok, fn field, :ok ->
      case create_payload_index(col, field) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_payload_index(col, field) do
    opts = [json: %{field_name: field, field_schema: "keyword"}] ++ req_opts()

    instrument(:create_payload_index, fn ->
      case Req.put("#{base_url()}/collections/#{col}/index?wait=true", opts) do
        {:ok, %{status: status}} when status in [200, 201] -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # On an existing collection, confirm it has the named `dense` vector + the
  # `keyword` sparse vector this build requires. A legacy single-unnamed-vector
  # collection would otherwise 400 every upsert/search silently. Pre-launch the
  # collection is recreated (wipeable); this guard catches a stale deploy.
  defp verify_collection_shape(col) do
    case collection_info(col) do
      {:ok, %{"config" => %{"params" => params}}} ->
        vectors = params["vectors"] || %{}
        sparse = params["sparse_vectors"] || %{}

        if is_map(vectors) and Map.has_key?(vectors, "dense") and Map.has_key?(sparse, "keyword") do
          :ok
        else
          {:error, {:incompatible_collection_schema, col}}
        end

      _ ->
        # Couldn't read collection info — don't block indexing on a transient
        # read error; the upsert will surface a real failure if shape is wrong.
        :ok
    end
  end

  @doc """
  Delete a collection. Idempotent: returns `:ok` for both 200 and 404.
  """
  def delete_collection(col) do
    opts = req_opts()

    instrument(:delete_collection, fn ->
      case Req.delete("#{base_url()}/collections/#{col}", opts) do
        {:ok, %{status: status}} when status in [200, 404] -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Get collection info. Returns the raw `result` map from Qdrant
  (includes config, point count, etc.).
  """
  def collection_info(col) do
    opts = req_opts()

    instrument(:collection_info, fn ->
      case Req.get("#{base_url()}/collections/#{col}", opts) do
        {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Upsert a batch of points. Each point: %{id: uuid_string, vector: [float], payload: map}.
  """
  def upsert_points(col \\ nil, points) do
    col = col || collection()

    serialized = Enum.map(points, fn p -> %{id: p.id, vector: p.vector, payload: p.payload} end)
    opts = [json: %{points: serialized}] ++ req_opts()

    instrument(:upsert, fn ->
      case Req.put("#{base_url()}/collections/#{col}/points", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Patch (overwrite-or-add) the given payload keys on the listed point ids.
  Vectors are untouched — this is the cost-free path for re-shaping payloads
  without re-running the embedder. Empty `point_ids` is a no-op.
  """
  def set_payload(col \\ nil, point_ids, payload)
  def set_payload(_col, [], _payload), do: :ok

  def set_payload(col, point_ids, payload) when is_list(point_ids) and is_map(payload) do
    col = col || collection()
    opts = [json: %{points: point_ids, payload: payload}] ++ req_opts()

    instrument(:set_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Patch (overwrite-or-add) payload keys on EVERY point matching the
  `{user_id, vault_id, path_hmac}` filter — vectors untouched. The cost-free
  way to re-path a note's points after a rename without re-running the
  embedder (#746). Triple-scope is mandatory: filtering on `path_hmac` alone
  could cross tenants if two users' folded HMACs collide.
  """
  def set_payload_by_filter(col \\ nil, user_id, vault_id, path_hmac, payload)
      when is_map(payload) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}},
        %{key: "path_hmac", match: %{value: path_hmac}}
      ]
    }

    opts = [json: %{filter: filter, payload: payload}] ++ req_opts()

    instrument(:set_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # #590: note-metadata fields that leaked as plaintext into payloads written
  # before the fix. Canonical list — the mix task and prod rpc both go through
  # delete_leaked_plaintext_keys/1 so this never drifts.
  @leaked_plaintext_keys ["source_path", "folder", "tags"]

  @doc """
  #590 backfill convenience: strip the known leaked plaintext keys
  (#{inspect(@leaked_plaintext_keys)}) from every existing point.

  Lives here (not in the Mix task) so it is callable from a release rpc,
  where `Mix` is not loaded:

      /app/bin/engram rpc 'Engram.Vector.Qdrant.delete_leaked_plaintext_keys() |> IO.inspect()'
  """
  def delete_leaked_plaintext_keys(col \\ nil),
    do: delete_payload_keys(col, @leaked_plaintext_keys)

  @doc """
  #590 backfill: delete the named payload keys from EVERY point in the
  collection (match-all filter). Vectors and all other payload keys are
  untouched — the cost-free way to strip leaked plaintext
  (`source_path`/`folder`/`tags`) from points written before the fix.
  Empty `keys` is a no-op.
  """
  def delete_payload_keys(col \\ nil, keys)
  def delete_payload_keys(_col, []), do: :ok

  def delete_payload_keys(col, keys) when is_list(keys) do
    col = col || collection()
    opts = [json: %{keys: keys, filter: %{must: []}}] ++ req_opts()

    instrument(:delete_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload/delete", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Delete all points for a given user+vault+path-hmac combination.

  T3.2 — `path_hmac` is the base64-encoded HMAC of the note path under the
  user's filter key. Qdrant payloads carry `path_hmac` as a plaintext-safe
  filter key alongside the encrypted `source_path` (Phase B.2.4).
  """
  def delete_by_note(col \\ nil, user_id, vault_id, path_hmac) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}},
        %{key: "path_hmac", match: %{value: path_hmac}}
      ]
    }

    opts = [json: %{filter: filter}] ++ req_opts()

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Exact count of points matching `{user_id, vault_id, path_hmac}`. Used by the
  repath worker (#746) to confirm points exist before/after a payload PATCH and
  to detect an embedded note whose points went missing.
  """
  def count_by_note(col \\ nil, user_id, vault_id, path_hmac) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}},
        %{key: "path_hmac", match: %{value: path_hmac}}
      ]
    }

    opts = [json: %{filter: filter, exact: true}] ++ req_opts()

    instrument(:count, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/count", opts) do
        {:ok, %{status: 200, body: %{"result" => %{"count" => count}}}} -> {:ok, count}
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Delete every point owned by `user_id` across all of their vaults. Used by
  the §C inactivity soft-delete path — single Qdrant call regardless of
  vault count.
  """
  def delete_by_user(col \\ nil, user_id) do
    col = col || collection()

    filter = %{must: [%{key: "user_id", match: %{value: user_id}}]}
    opts = [json: %{filter: filter}] ++ req_opts()

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Delete all points for a given user+vault combination (vault-level cleanup).
  """
  def delete_by_vault(col \\ nil, user_id, vault_id) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}}
      ]
    }

    opts = [json: %{filter: filter}] ++ req_opts()

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  T3.7 — scrolls all points matching a filter, paginated. Used by the
  DEK-rotation orchestrator to re-encrypt every point in a user's tenant
  without touching vectors.

  Options:
    * `:filter` — a Qdrant filter map, e.g. `%{must: [%{key: "user_id", match: %{value: 42}}]}`
    * `:limit` — page size (default 200)
    * `:offset` — opaque page-token returned from a prior call's `next_page_offset` (nil on first call)
    * `:with_payload` — defaults to `true`
    * `:with_vector` — defaults to `false`

  Returns `{:ok, %{points: [...], next_page_offset: term() | nil}} | {:error, term()}`.
  """
  def scroll(col \\ nil, opts) when is_list(opts) do
    collection_name = col || collection()
    url = "#{base_url()}/collections/#{collection_name}/points/scroll"

    body = %{
      filter: Keyword.fetch!(opts, :filter),
      with_payload: Keyword.get(opts, :with_payload, true),
      with_vector: Keyword.get(opts, :with_vector, false),
      limit: Keyword.get(opts, :limit, 200)
    }

    body =
      case Keyword.get(opts, :offset) do
        nil -> body
        offset -> Map.put(body, :offset, offset)
      end

    instrument(:scroll, fn ->
      case Req.post(url, [json: body] ++ req_opts()) do
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"result" => %{"points" => points, "next_page_offset" => next}}
         }} ->
          {:ok, %{points: points, next_page_offset: next}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:qdrant_scroll, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Vector similarity search. Returns list of result structs with score + payload.

  Options:
  - `:user_id`     — filter to this user's points (required for tenant isolation)
  - `:vault_id`    — filter to a specific vault (omit for cross-vault search)
  - `:limit`       — number of results (default 5)
  - `:folder_hmac` — filter to points whose folder_hmac equals this value
                     (Phase B.2.3 — base64-encoded HMAC, no plaintext folder)
  - `:tags_hmac`   — filter to points with ANY of these tag HMACs
                     (Phase B.2.3 — base64-encoded list, no plaintext tags)
  """
  def search(col \\ nil, vector, search_opts) do
    col = col || collection()

    instrument(:search, fn ->
      do_search(col, [json: search_body(vector, search_opts)] ++ req_opts(:search))
    end)
  end

  @doc false
  def search_body(vector, search_opts) do
    base = %{
      query: vector,
      using: "dense",
      filter: tenant_filter(search_opts),
      limit: Keyword.get(search_opts, :limit, 5),
      with_payload: true
    }

    base
    |> then(fn b ->
      case quantization_params(search_opts) do
        nil -> b
        params -> Map.put(b, :params, params)
      end
    end)
    |> maybe_with_vector(search_opts)
  end

  # Per-query quantization params. full_precision bypasses binary quant
  # (exact-cosine traversal over full floats); otherwise the binary funnel.
  defp quantization_params(search_opts) do
    cond do
      Keyword.get(search_opts, :full_precision, false) ->
        %{quantization: %{ignore: true}}

      binary_quantization_enabled?() ->
        %{quantization: %{rescore: true, oversampling: 3.0}}

      true ->
        nil
    end
  end

  defp maybe_with_vector(body, search_opts) do
    if Keyword.get(search_opts, :with_vector, false),
      do: Map.put(body, :with_vector, ["dense"]),
      else: body
  end

  # Extracted from search/3 so all three query shapes share tenant filtering.
  defp tenant_filter(search_opts) do
    user_id = Keyword.fetch!(search_opts, :user_id)
    vault_id = Keyword.get(search_opts, :vault_id)
    tags_hmac = Keyword.get(search_opts, :tags_hmac)
    folder_hmac = Keyword.get(search_opts, :folder_hmac)

    must = [%{key: "user_id", match: %{value: user_id}}]
    must = if vault_id, do: must ++ [%{key: "vault_id", match: %{value: vault_id}}], else: must
    must = if tags_hmac, do: [%{key: "tags_hmac", match: %{any: tags_hmac}} | must], else: must

    must =
      if folder_hmac, do: [%{key: "folder_hmac", match: %{value: folder_hmac}} | must], else: must

    %{must: must}
  end

  @doc """
  Keyword-only search against the sparse `keyword` vector. `sparse` is
  `%{indices: [u32], values: [float]}`. Same options as `search/3`.
  """
  def sparse_search(col \\ nil, sparse, search_opts) do
    col = col || collection()

    instrument(:sparse_search, fn ->
      do_search(col, [json: sparse_search_body(sparse, search_opts)] ++ req_opts(:search))
    end)
  end

  @doc false
  def sparse_search_body(sparse, search_opts) do
    %{
      query: %{indices: sparse.indices, values: sparse.values},
      using: "keyword",
      filter: tenant_filter(search_opts),
      limit: Keyword.get(search_opts, :limit, 5),
      with_payload: true
    }
    |> maybe_with_vector(search_opts)
  end

  @doc """
  Hybrid search: dense + keyword prefetches fused server-side by RRF in one
  request. `sparse` is `%{indices, values}`. Tenant filter is applied to BOTH
  legs (load-bearing — the sparse inverted index is global).
  """
  def hybrid_search(col \\ nil, dense, sparse, search_opts) do
    col = col || collection()

    instrument(:hybrid_search, fn ->
      do_search(col, [json: hybrid_search_body(dense, sparse, search_opts)] ++ req_opts(:search))
    end)
  end

  @doc false
  def hybrid_search_body(dense, sparse, search_opts) do
    filter = tenant_filter(search_opts)
    limit = Keyword.get(search_opts, :limit, 5)

    dense_leg =
      %{query: dense, using: "dense", filter: filter, limit: limit}
      |> then(fn leg ->
        case quantization_params(search_opts) do
          nil -> leg
          params -> Map.put(leg, :params, params)
        end
      end)

    %{
      prefetch: [
        dense_leg,
        %{
          query: %{indices: sparse.indices, values: sparse.values},
          using: "keyword",
          filter: filter,
          limit: limit
        }
      ],
      query: %{fusion: "rrf"},
      limit: limit,
      with_payload: true
    }
    |> maybe_with_vector(search_opts)
  end

  defp do_search(col, opts) do
    case Req.post("#{base_url()}/collections/#{col}/points/query", opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        points = if is_list(result), do: result, else: result["points"] || []

        results =
          Enum.map(points, fn p ->
            payload = p["payload"] || %{}

            %{
              score: p["score"],
              vector: get_in(p, ["vector", "dense"]),
              text: Map.get(payload, "text"),
              title: Map.get(payload, "title"),
              heading_path: Map.get(payload, "heading_path"),
              # #590: new points carry no plaintext source_path/tags — these
              # read nil/[] and Search.rehydrate_display_fields/2 refills them
              # from the encrypted notes row. Kept as a fallback for old points
              # not yet stripped by the backfill (delete_leaked_plaintext_keys).
              source_path: Map.get(payload, "source_path"),
              tags: Map.get(payload, "tags") || [],
              vault_id: Map.get(payload, "vault_id"),
              qdrant_id: p["id"],
              # Nonce keys are only present on encrypted-vault chunks; nil otherwise.
              text_nonce: Map.get(payload, "text_nonce"),
              title_nonce: Map.get(payload, "title_nonce"),
              heading_path_nonce: Map.get(payload, "heading_path_nonce"),
              # T3.6 — present on AAD-bound payloads (>= v2). Drives the
              # bind-vs-empty AAD decision in `Engram.Crypto.qdrant_aad/3`.
              aad_version: Map.get(payload, "aad_version")
            }
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new()
          end)

        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
