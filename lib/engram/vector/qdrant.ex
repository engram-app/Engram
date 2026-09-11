defmodule Engram.Vector.Qdrant do
  @moduledoc """
  Thin Req-based HTTP wrapper for the Qdrant REST API.
  All operations target a single collection.

  Config:
  - :qdrant_url — base URL (default http://localhost:6333)
  - QDRANT_API_KEY env var — API key for Qdrant Cloud (optional for local)
  """

  use Engram.Cache.PersistentTerm

  alias Engram.ServiceConfig

  @default_url "http://localhost:6333"
  @default_collection "obsidian_notes"

  # Payload fields every tenant-scoped op filters on. Qdrant Cloud strict-mode
  # rejects (400) a filter on an un-indexed field, so each must have a keyword
  # index before any upsert/search/delete. `note_id` is not a live filter key
  # today (deletes resolve via `path_hmac`) but is indexed to match the prod
  # collection + future-proof. See #626. `type_hmac` is the OKF frontmatter
  # `type` blind index (spec 2026-07-02). `folder_hmac`/`tags_hmac` are the
  # folder and tag search filters (#1609).
  @payload_index_fields ~w(user_id vault_id note_id path_hmac type_hmac folder_hmac tags_hmac)

  # OKF frontmatter dates are stored plaintext (see build_prepared/6) so
  # Qdrant can range-filter on them; they need an integer payload index
  # rather than keyword.
  @integer_payload_index_fields ~w(fm_timestamp fm_created)

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
      # Default 5s fail-fast; overridable per-process so a Bypass test can pin a
      # generous budget and not misread scheduler starvation as a real timeout.
      receive_timeout: ServiceConfig.get(:qdrant_search_timeout, 5_000),
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

  Also creates the keyword/integer payload indexes every tenant-scoped filter
  depends on (#626, extended for OKF frontmatter fields). On an existing
  collection it creates only the ones its `payload_schema` lacks (#1609), so
  a field added to the list later reaches an already-deployed collection on
  the next boot instead of needing an out-of-band PUT.

  Cost: the `payload_schema` comes from the `collection_info` GET the shape
  check already makes, so a fully indexed collection adds no requests. The
  whole call is memoised per node (#1501), so this runs once per boot.
  """
  def ensure_collection(col \\ nil, dims) do
    col = col || collection()
    key = {base_url(), col, dims}

    # Memoised per node, per {url, collection, dims}. `Indexing.prepare_index/3`
    # calls this for EVERY note, and on an existing collection the work is two
    # network round trips that cannot produce a different answer: a PUT that
    # 409s, then a `collection_info` GET to verify shape. Measured in prod
    # 2026-08-28 — 853 `ensure_collection` and 853 `collection_info` calls
    # against 853 upserts, a 1:1:1 ratio, inside the slowest queue we have
    # (embed averages 738 ms). See #1501.
    #
    # Keyed on the resolved base URL, not just the collection name. That was
    # meant to keep the Bypass suites isolated — "each test's port is its own
    # key" — and it does not, which is why the memo is OFF under `:test` (see
    # `memo_enabled?/0`). A port is only unique while it is held: Bypass
    # releases it on test exit and the OS hands the same number to a later
    # `Bypass.open/0`, whose key then hits a marker the earlier test wrote.
    # `ensure_collection/2` returns `:ok` having issued no request at all, and
    # any test whose only HTTP comes from here dies in `Bypass`'s exit
    # verification with "No HTTP request arrived at Bypass" — far from the
    # cause, in a test that did nothing wrong. Measured directly: 8 requests on
    # a cold memo, 0 after reopening Bypass on the same port.
    #
    # A blanket `forget_collection_memo/0` in shared setup is NOT the fix. It
    # erases the whole namespace, so one async test would clear another's
    # marker mid-run and add unexpected requests — and `indexing_test.exs` and
    # `search_test.exs` both use `Bypass.expect_once`. That trades a
    # missing-request flake for a surplus-request one.
    #
    # ONLY success is memoised. A failure erases the entry so the next caller
    # retries — otherwise one transient Qdrant blip would be cached for the
    # life of the node and every subsequent index would fail against a
    # collection that was fine.
    # Deliberately NOT `pt_fetch/2`: that helper is read-through and caches
    # whatever the loader returns, so an error would be written and only then
    # erased. In the window between those two steps a concurrent caller reads
    # the cached error and fails WITHOUT attempting the network — turning one
    # transient Qdrant blip into several. Writing only on success closes that
    # window rather than cleaning up after it. Same `{__MODULE__, key}`
    # namespace, so `pt_erase_all/0` still finds these.
    if memo_enabled?() do
      case :persistent_term.get({__MODULE__, key}, :__miss__) do
        :ok ->
          :ok

        :__miss__ ->
          case do_ensure_collection(col, dims) do
            :ok ->
              :persistent_term.put({__MODULE__, key}, :ok)
              :ok

            {:error, _} = error ->
              error
          end
      end
    else
      do_ensure_collection(col, dims)
    end
  end

  # Defaults to on, so prod and dev keep #1501's saving; `config/test.exs`
  # turns it off. Switched rather than cleared because a switch cannot be
  # defeated by test ordering — there is no marker to leak in the first place,
  # so no async test can observe or erase another's. The one suite that exists
  # to test the memo turns it back on for itself.
  defp memo_enabled?, do: Application.get_env(:engram, :ensure_collection_memo, true)

  @doc """
  Drop the memoised "this collection is ready" marker for the current node.

  Needed if the collection is dropped or recreated out of band: without this
  the node keeps skipping `ensure_collection` and upserts fail against a
  collection that no longer exists. Not wired to anything automatic — a
  drop/recreate is a deliberate operator action, and this is the deliberate
  counterpart.
  """
  def forget_collection_memo, do: pt_erase_all()

  defp do_ensure_collection(col, dims) do
    case create_collection(col, dims) do
      {:ok, :created} -> ensure_payload_indexes(col, MapSet.new())
      {:ok, {:exists, indexed}} -> ensure_payload_indexes(col, indexed)
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
  # and report which fields it already indexes.
  defp existing_collection(col) do
    with {:ok, indexed} <- verify_collection_shape(col), do: {:ok, {:exists, indexed}}
  end

  # Create a payload index for every filtered field the collection lacks.
  # `?wait=true` blocks until each index is ready so the next upsert or search
  # can't race an unbuilt one. Stops at the first failure so a real error
  # surfaces (and is not memoised). Keyword fields are equality/any-match
  # filters; integer fields (the OKF dates) are range filters.
  #
  # Runs on an EXISTING collection too, not just after a fresh create (#1609).
  # Create-only meant a field added to the list later never reached a
  # collection that already existed: prod indexed only the first four, and
  # strict mode 400'd every folder, tag, type and date filter.
  #
  # ponytail: `:unknown` (collection_info unreadable) skips the check, and the
  # memo then holds `:ok` until the node restarts. Another node or the next
  # boot reconciles; make it retry if a transient read ever strands an index.
  defp ensure_payload_indexes(_col, :unknown), do: :ok

  defp ensure_payload_indexes(col, indexed) do
    keyword = Enum.map(@payload_index_fields, &{&1, "keyword"})
    integer = Enum.map(@integer_payload_index_fields, &{&1, "integer"})

    (keyword ++ integer)
    |> Enum.reject(fn {field, _schema} -> MapSet.member?(indexed, field) end)
    |> Enum.reduce_while(:ok, fn {field, schema}, :ok ->
      case create_payload_index(col, field, schema) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_payload_index(col, field, schema) do
    opts = [json: %{field_name: field, field_schema: schema}] ++ req_opts()

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
      {:ok, %{"config" => %{"params" => params}} = info} ->
        vectors = params["vectors"] || %{}
        sparse = params["sparse_vectors"] || %{}

        if is_map(vectors) and Map.has_key?(vectors, "dense") and Map.has_key?(sparse, "keyword") do
          {:ok, indexed_fields(info)}
        else
          {:error, {:incompatible_collection_schema, col}}
        end

      _ ->
        # Couldn't read collection info — don't block indexing on a transient
        # read error; the upsert will surface a real failure if shape is wrong.
        {:ok, :unknown}
    end
  end

  defp indexed_fields(info), do: MapSet.new(Map.keys(info["payload_schema"] || %{}))

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
  Delete the listed point ids outright. Empty list is a no-op.

  The identity-safe delete: point ids come from `chunks.qdrant_point_id`, so
  this reaches a note's points no matter what its `path_hmac` has since become.
  `delete_by_note/4` cannot — a rename retags the note row while the points keep
  the old hmac, and the filter then matches nothing. Callers use both.
  """
  def delete_points(col \\ nil, point_ids)
  def delete_points(_col, []), do: :ok

  def delete_points(col, point_ids) when is_list(point_ids) do
    col = col || collection()
    opts = [json: %{points: point_ids}] ++ req_opts()

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
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
      filter: build_tenant_filter(search_opts),
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

  @doc false
  # Public for filter-shape tests only (test/engram/vector/qdrant_filter_test.exs).
  # Extracted from search/3 so all three query shapes share tenant + OKF
  # frontmatter filtering.
  def build_tenant_filter(search_opts) do
    user_id = Keyword.fetch!(search_opts, :user_id)
    vault_id = Keyword.get(search_opts, :vault_id)
    tags_hmac = Keyword.get(search_opts, :tags_hmac)
    folder_hmac = Keyword.get(search_opts, :folder_hmac)
    type_hmac = Keyword.get(search_opts, :type_hmac)

    must = [%{key: "user_id", match: %{value: user_id}}]
    # `vault_id` accepts one id or a set. The set form is what a multi-vault
    # OAuth grant (and a subset-restricted API key) needs: without it the only
    # options were one query per vault or dropping the filter entirely, and
    # dropping it leaks every vault the credential was scoped away from (#729).
    # `vault_id` is already a keyword payload index (@payload_index_fields), so
    # `any` needs no new index — same shape as tags_hmac below.
    must =
      case vault_id do
        nil -> must
        id when is_binary(id) -> must ++ [%{key: "vault_id", match: %{value: id}}]
        ids when is_list(ids) -> must ++ [%{key: "vault_id", match: %{any: ids}}]
      end

    must = if tags_hmac, do: [%{key: "tags_hmac", match: %{any: tags_hmac}} | must], else: must

    must =
      if folder_hmac, do: [%{key: "folder_hmac", match: %{value: folder_hmac}} | must], else: must

    must =
      if type_hmac, do: [%{key: "type_hmac", match: %{value: type_hmac}} | must], else: must

    must
    |> add_range_clause("fm_timestamp", search_opts, :fm_timestamp_gte, :fm_timestamp_lte)
    |> add_range_clause("fm_created", search_opts, :fm_created_gte, :fm_created_lte)
    |> then(&%{must: &1})
  end

  defp add_range_clause(must, key, opts, gte_key, lte_key) do
    range =
      %{}
      |> maybe_put_bound(:gte, Keyword.get(opts, gte_key))
      |> maybe_put_bound(:lte, Keyword.get(opts, lte_key))

    if range == %{}, do: must, else: must ++ [%{key: key, range: range}]
  end

  defp maybe_put_bound(range, _bound, nil), do: range
  defp maybe_put_bound(range, bound, value), do: Map.put(range, bound, value)

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
      filter: build_tenant_filter(search_opts),
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
    filter = build_tenant_filter(search_opts)
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
