defmodule Engram.Embedders.Voyage do
  @moduledoc """
  Voyage AI embedder adapter. Calls the Voyage AI REST API via Req.
  Reads config: VOYAGE_API_KEY, EMBED_MODEL (default voyage-4-large).

  Client-side rate limiting is split by `purpose` (`:query` vs `:index`) so a
  bulk indexing burst cannot starve synchronous user search. Callers should
  pass `purpose: :query` for search/RAG paths; everything else (EmbedNote
  worker, parity validation, future batch jobs) is treated as `:index`.

  ## Telemetry

    * `[:engram, :voyage, :embed, :start | :stop | :exception]` — request
      span. Stop metadata: `%{status: ..., purpose: ...}`.
    * `[:engram, :voyage, :embed, :tokens]` — emitted on a successful 200
      response when the Voyage payload includes `usage.total_tokens`.
      Measurements: `%{total_tokens: pos_integer()}`. Metadata:
      `%{purpose: :index | :query}`. Drives the
      `engram_prom_ex_voyage_embed_tokens_total` sum metric used by the
      Grafana cost / tokens-per-minute panels. Voyage publishes no usage
      API, so this is the only telemetry path for billing reconciliation.
    * `[:engram, :embed, :client_rate_limited]` — synthetic-429s emitted
      when the in-process Hammer throttle fast-fails a request before
      reaching Voyage.
  """

  @behaviour Engram.Embedder

  # Compile-time gate: the test-only `:voyage_throttle_key` config override
  # (used to give async test cases unique bucket keys) must be structurally
  # absent in non-test builds. Mirrors `EngramWeb.Plugs.RateLimit`'s
  # `@is_test_build` pattern at lib/engram_web/plugs/rate_limit.ex:11-12.
  @build_env Application.compile_env(:engram, :env, :prod)
  @is_test_build @build_env == :test

  @default_url "https://api.voyageai.com"
  @default_model "voyage-4-large"

  @impl true
  def model_info do
    %{
      model: Application.get_env(:engram, :embed_model, @default_model),
      dimensions: Application.get_env(:engram, :embed_dims, 1024)
    }
  end

  @impl true
  def embed_texts(texts) when is_list(texts), do: embed_texts(texts, [])

  @impl true
  def embed_texts(texts, opts) when is_list(texts) do
    purpose = Keyword.get(opts, :purpose, :index)

    # Span tracks every request reaching the network OR fast-failing the
    # client-side throttle. The synthetic-429 path emits its own
    # `[:engram, :embed, :client_rate_limited]` counter (handled by the
    # PromEx Voyage plugin); here we still flag it `status: :throttled` so
    # the Voyage `embed_total` rate isn't dragged down by silent drops.
    :telemetry.span(
      [:engram, :voyage, :embed],
      %{purpose: purpose, text_count: length(texts)},
      fn ->
        result =
          with :ok <- throttle_check(opts) do
            do_embed_texts(texts, opts)
          end

        {result, %{purpose: purpose, status: status_label(result)}}
      end
    )
  end

  defp status_label({:ok, _}), do: :ok
  defp status_label({:error, {429, %{"detail" => "client_rate_limited"}}}), do: :throttled

  defp status_label({:error, {status, _}}) when is_integer(status) and status >= 500,
    do: :server_error

  defp status_label({:error, {status, _}}) when is_integer(status), do: :client_error
  defp status_label({:error, _}), do: :error

  @doc """
  Default Req options per embed purpose.

  `:query` backs synchronous user search — the request process is pinned
  for the whole call, so a Voyage brownout must fail fast (one attempt,
  short timeout) instead of holding searches for up to ~2 minutes.
  `:index` runs in Oban workers where patient retries are the right call.
  Explicit caller opts always win over these defaults.
  """
  @spec request_defaults(atom()) :: keyword()
  def request_defaults(:query), do: [receive_timeout: 5_000, retry: false]
  def request_defaults(_purpose), do: [receive_timeout: 30_000, retry: :transient, max_retries: 3]

  defp do_embed_texts(texts, opts) do
    url = Application.get_env(:engram, :voyage_url, @default_url)
    model = Keyword.get(opts, :model, Application.get_env(:engram, :embed_model, @default_model))

    api_key =
      Application.get_env(:engram, :voyage_api_key) ||
        raise "VOYAGE_API_KEY not configured (set VOYAGE_API_KEY env var)"

    {req_opts, _} = Keyword.split(opts, [:retry, :max_retries, :receive_timeout])
    purpose = Keyword.get(opts, :purpose, :index)

    result =
      Req.post(
        "#{url}/v1/embeddings",
        [
          json: %{input: texts, model: model},
          headers: [{"authorization", "Bearer #{api_key}"}]
        ] ++ Keyword.merge(request_defaults(purpose), req_opts)
      )

    case result do
      {:ok, %{status: 200, body: %{"data" => data} = body}} ->
        vectors = Enum.map(data, & &1["embedding"])
        emit_token_telemetry(body, Keyword.get(opts, :purpose, :index))
        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Voyage's `/v1/embeddings` 200 response always carries a `usage` object
  # with `total_tokens`. The field is the only billing-relevant signal — no
  # public usage API exists — so we lift it into a telemetry event for the
  # PromEx `tokens_total` sum metric. Absence-of-event is the contract when
  # the field is missing: a future endpoint shape change should not surface
  # as silently-zero tokens.
  defp emit_token_telemetry(%{"usage" => %{"total_tokens" => total}}, purpose)
       when is_integer(total) do
    :telemetry.execute(
      [:engram, :voyage, :embed, :tokens],
      %{total_tokens: total},
      %{purpose: purpose}
    )
  end

  defp emit_token_telemetry(_body, _purpose), do: :ok

  # Client-side rate limit. Enabled when `:voyage_rpm` is set (env: VOYAGE_RPM).
  # When the bucket is empty we synthesize the same `{:error, {429, body}}`
  # shape Voyage returns on a real rate-limit response, so callers (notably
  # `Engram.Workers.EmbedNote`) handle both paths identically — the
  # snooze-on-429 logic fires for either case.
  #
  # `retry_after_ms` is included for the synthetic path. Voyage's REAL 429
  # response signals retry hints via the `Retry-After` HTTP header (in
  # seconds), NOT a JSON body field. Callers reading `body["retry_after_ms"]`
  # work only against the synthetic path; for real 429s, read the header.
  #
  # Bucket is partitioned by `purpose` (`:query` vs `:index`, default
  # `:index`) so a bulk indexing burst cannot exhaust the budget used by
  # synchronous user search. Each gets its own bucket and its own RPM
  # allowance: `:engram, :voyage_query_rpm` falls back to `:voyage_rpm`
  # when unset, so operators can flip on the split without re-tuning.
  defp throttle_check(opts) do
    purpose = Keyword.get(opts, :purpose, :index)

    case rpm_for(purpose) do
      nil ->
        :ok

      rpm when is_integer(rpm) and rpm > 0 ->
        key = bucket_key(purpose)

        case EngramWeb.RateLimiter.hit(key, 60_000, rpm) do
          {:allow, _count} ->
            :ok

          {:deny, retry_after_ms} ->
            :telemetry.execute(
              [:engram, :embed, :client_rate_limited],
              %{count: 1, retry_after_ms: retry_after_ms},
              %{rpm: rpm, purpose: purpose}
            )

            {:error,
             {429, %{"detail" => "client_rate_limited", "retry_after_ms" => retry_after_ms}}}
        end
    end
  end

  defp rpm_for(:query) do
    Application.get_env(:engram, :voyage_query_rpm) ||
      Application.get_env(:engram, :voyage_rpm)
  end

  defp rpm_for(_), do: Application.get_env(:engram, :voyage_rpm)

  # In test builds the bucket key honors `:voyage_throttle_key` so async test
  # cases can use per-test keys and avoid collisions on the shared ETS limiter
  # table. In non-test builds the override is structurally absent — operators
  # cannot point a prod node at an arbitrary bucket key.
  if @is_test_build do
    defp bucket_key(purpose) do
      base = Application.get_env(:engram, :voyage_throttle_key, "voyage_embed")
      "#{base}:#{purpose}"
    end
  else
    defp bucket_key(purpose), do: "voyage_embed:#{purpose}"
  end
end
