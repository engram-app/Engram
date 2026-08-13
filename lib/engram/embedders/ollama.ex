defmodule Engram.Embedders.Ollama do
  @moduledoc """
  Ollama embedder adapter for self-hosted inference.
  Uses the /api/embed endpoint (Ollama 0.3+).
  Reads config: OLLAMA_URL (default http://localhost:11434), EMBED_MODEL (nomic-embed-text).
  """

  @behaviour Engram.Embedder

  @default_url "http://localhost:11434"
  @default_model "nomic-embed-text"

  @doc """
  Default Req options per embed purpose. Mirrors `Engram.Embedders.Voyage`.

  `:index` runs in Oban workers against an often-remote Ollama endpoint (e.g.
  FastRaid over the LAN), where patient retries are the right call: a single
  connection-level blip otherwise fails the whole Oban attempt and waits out the
  job backoff (~30s). Retry the FAST transient failures in-call so a bounced
  container / momentary 5xx doesn't burn an attempt.

  `:query` backs synchronous user search — a person, or an MCP client like
  Claude Desktop, is blocked on the call. Ollama serializes requests, so a query
  embed queues behind the embed worker's 128-chunk index batches
  (`Indexing.@embed_batch_size`). Measured 2026-08-12 against FastRaid with
  `mxbai-embed-large`: ~0.12s idle, but ~4.3s / ~8.4s / ~13.1s behind 1 / 2 / 3
  in-flight index batches. At the `:index` budget a self-hosted search would
  hang for two minutes rather than answer.

  Failing fast is not a lost search: hybrid mode degrades to keyword-only when
  the embed leg errors (`Engram.Search.run_legs/5`), and hybrid is the default
  for BOTH real entry points (`Handlers.search_mode/1` and
  `SearchController.parse_mode/1` map unknown → `:hybrid`). An explicit
  `mode: "vector"` caller still gets an error — but a fast error beats a hang
  there too.

  Two deliberate divergences from Voyage's `:query` defaults:

    * **15s, not 5s.** Voyage's 5s guards a remote brownout; ours guards local
      queueing, and 5s would drop to keyword-only almost any time indexing runs.
      15s clears the measured 3-batch depth while staying well inside any MCP
      client's patience.
    * **Retries kept, not `retry: false`.** Voyage disables them because its
      `:transient` policy also retries timeouts, which would multiply the
      budget. `retry_fast_transient?/2` already refuses to retry a
      `receive_timeout`, so retries here stay bounded and cheap — a bounced
      container shouldn't fail a user's search.

  Explicit caller opts always win over these defaults (tests pass a
  `plug`/`retry_delay`). Public only so the budgets can be unit-tested without a
  live Ollama — the same reason `retry_fast_transient?/2` is public.
  """
  @spec request_defaults(atom()) :: keyword()
  def request_defaults(:query),
    do: [receive_timeout: 15_000, retry: &__MODULE__.retry_fast_transient?/2, max_retries: 3]

  def request_defaults(_purpose),
    do: [receive_timeout: 120_000, retry: &__MODULE__.retry_fast_transient?/2, max_retries: 3]

  # Retry only failures that fail FAST. A receive_timeout means Ollama accepted
  # the connection but is hanging; retrying it up to max_retries would multiply
  # the 120s timeout into a multi-minute stall — and a sustained outage is
  # already covered by the outer Oban attempt + ReconcileEmbeddings. Connection
  # blips (econnrefused/closed) and 5xx return immediately, so retrying THEM is
  # cheap. Public (not private) only so it can be captured here and unit-tested.
  @doc false
  def retry_fast_transient?(_req, %Req.TransportError{reason: :timeout}), do: false
  def retry_fast_transient?(_req, %Req.TransportError{}), do: true
  def retry_fast_transient?(_req, %{status: status}) when status in [500, 502, 503, 504], do: true
  def retry_fast_transient?(_req, _), do: false

  @impl true
  def model_info do
    %{
      model: Application.get_env(:engram, :embed_model, @default_model),
      dimensions: Application.get_env(:engram, :embed_dims, 768)
    }
  end

  @impl true
  def embed_texts(texts) when is_list(texts), do: embed_texts(texts, [])

  @impl true
  def embed_texts(texts, opts) when is_list(texts) do
    url = System.get_env("OLLAMA_URL", @default_url)
    model = Application.get_env(:engram, :embed_model, @default_model)

    # `:purpose` is OUR routing hint, not a Req option — the split drops it, so
    # it can never reach Req as an unknown option.
    {req_opts, _} =
      Keyword.split(opts, [:retry, :max_retries, :retry_delay, :receive_timeout, :plug])

    purpose = Keyword.get(opts, :purpose, :index)

    result =
      Req.post(
        "#{url}/api/embed",
        [json: %{model: model, input: texts}] ++
          Keyword.merge(request_defaults(purpose), req_opts)
      )

    case result do
      {:ok, %{status: 200, body: %{"embeddings" => vectors}}} ->
        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
