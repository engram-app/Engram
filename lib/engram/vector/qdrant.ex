defmodule Engram.Vector.Qdrant do
  @moduledoc """
  Thin Req-based HTTP wrapper for the Qdrant REST API.
  All operations target a single collection.

  Config:
  - :qdrant_url — base URL (default http://localhost:6333)
  - QDRANT_API_KEY env var — API key for Qdrant Cloud (optional for local)
  """

  @default_url "http://localhost:6333"
  @default_collection "obsidian_notes"

  defp base_url, do: Application.get_env(:engram, :qdrant_url, @default_url)
  defp collection, do: Application.get_env(:engram, :qdrant_collection, @default_collection)

  @doc "Returns the configured Qdrant collection name (env-var-driven)."
  def collection_name, do: collection()

  defp binary_quantization_enabled?,
    do: Application.get_env(:engram, :qdrant_binary_quantization, true)

  defp req_opts do
    {retry, max_retries} =
      case Application.get_env(:engram, :qdrant_retry, :transient) do
        false -> {false, 0}
        mode -> {mode, 3}
      end

    base = [
      receive_timeout: 30_000,
      retry: retry,
      max_retries: max_retries,
      retry_log_level: :warning,
      connect_options: [protocols: [:http1]]
    ]

    case Application.get_env(:engram, :qdrant_api_key) do
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
  """
  def ensure_collection(col \\ nil, dims) do
    col = col || collection()

    vectors = %{size: dims, distance: "Cosine"}

    body =
      if binary_quantization_enabled?() do
        %{vectors: vectors, quantization_config: %{binary: %{always_ram: true}}}
      else
        %{vectors: vectors}
      end

    opts = [json: body] ++ req_opts()

    case Req.put("#{base_url()}/collections/#{col}", opts) do
      {:ok, %{status: status}} when status in [200, 201, 409] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a collection. Idempotent: returns `:ok` for both 200 and 404.
  """
  def delete_collection(col) do
    opts = req_opts()

    case Req.delete("#{base_url()}/collections/#{col}", opts) do
      {:ok, %{status: status}} when status in [200, 404] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get collection info. Returns the raw `result` map from Qdrant
  (includes config, point count, etc.).
  """
  def collection_info(col) do
    opts = req_opts()

    case Req.get("#{base_url()}/collections/#{col}", opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Upsert a batch of points. Each point: %{id: uuid_string, vector: [float], payload: map}.
  """
  def upsert_points(col \\ nil, points) do
    col = col || collection()

    serialized = Enum.map(points, fn p -> %{id: p.id, vector: p.vector, payload: p.payload} end)
    opts = [json: %{points: serialized}] ++ req_opts()

    case Req.put("#{base_url()}/collections/#{col}/points", opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
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

    case Req.post("#{base_url()}/collections/#{col}/points/payload", opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
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

    case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
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

    case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
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

    case Req.post(url, [json: body] ++ req_opts()) do
      {:ok, %Req.Response{status: 200, body: %{"result" => %{"points" => points, "next_page_offset" => next}}}} ->
        {:ok, %{points: points, next_page_offset: next}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:qdrant_scroll, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
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
    user_id = Keyword.fetch!(search_opts, :user_id)
    vault_id = Keyword.get(search_opts, :vault_id)
    limit = Keyword.get(search_opts, :limit, 5)
    tags_hmac = Keyword.get(search_opts, :tags_hmac)
    folder_hmac = Keyword.get(search_opts, :folder_hmac)

    must = [%{key: "user_id", match: %{value: user_id}}]
    must = if vault_id, do: must ++ [%{key: "vault_id", match: %{value: vault_id}}], else: must

    must =
      if tags_hmac,
        do: [%{key: "tags_hmac", match: %{any: tags_hmac}} | must],
        else: must

    must =
      if folder_hmac,
        do: [%{key: "folder_hmac", match: %{value: folder_hmac}} | must],
        else: must

    base = %{
      query: vector,
      filter: %{must: must},
      limit: limit,
      with_payload: true
    }

    body =
      if binary_quantization_enabled?() do
        Map.put(base, :params, %{quantization: %{rescore: true, oversampling: 3.0}})
      else
        base
      end

    opts = [json: body] ++ req_opts()

    case Req.post("#{base_url()}/collections/#{col}/points/query", opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        points = if is_list(result), do: result, else: result["points"] || []

        results =
          Enum.map(points, fn p ->
            payload = p["payload"] || %{}

            %{
              score: p["score"],
              text: Map.get(payload, "text"),
              title: Map.get(payload, "title"),
              heading_path: Map.get(payload, "heading_path"),
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
