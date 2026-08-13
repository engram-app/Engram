defmodule Engram.Embedders.Ollama do
  @moduledoc """
  Ollama embedder adapter for self-hosted inference.
  Uses the /api/embed endpoint (Ollama 0.3+).
  Reads config: OLLAMA_URL (default http://localhost:11434), EMBED_MODEL (nomic-embed-text).
  """

  @behaviour Engram.Embedder

  alias Engram.Logger.Metadata

  require Logger

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

  Timing out is not a lost search: hybrid mode degrades to keyword-only when the
  embed leg errors (`Engram.Search.run_legs/5`), and hybrid is the default for
  BOTH real entry points (`Handlers.search_mode/1` and
  `SearchController.parse_mode/1` map unknown → `:hybrid`). An explicit
  `mode: "vector"` caller still gets an error — but a bounded error beats a hang
  there too.

  **Why 45s and not something tight.** That degradation is the reason this
  budget must NOT sit near the measured contention. The first cut of this change
  used 15s, which is only ~1.9s above the measured 3-batch depth — under the
  very load this whole change exists to survive, the embed would time out, the
  vector leg would silently vanish, and a cross-vault search test would pass on
  the sparse leg while appearing to prove the semantic path. That closes a flake
  by deleting the thing under test. 45s clears the measured depths with real
  margin (depth 4 extrapolates to ~17s) while still bounding the user-blocking
  hang to something an MCP client tolerates, which was the actual goal — the
  point was never "fail fast", it was "do not hang for two minutes".

  **The cost of 45s, stated plainly.** `Qdrant.req_opts(:search)` uses 5s
  precisely because a brownout that pins each request for minutes holds Bandit
  processes and cascades into pool pressure, and Voyage's `:query` is 5s for the
  same reason. 45s accepts that risk on the Ollama path: a self-host Ollama that
  accepts connections but hangs (e.g. loading a model) will pin one request
  process per concurrent search for up to ~45s, with no concurrency cap in front
  of it. That is a deliberate trade — a tight budget here deletes the vector leg
  under ordinary indexing load (see above), which is worse for a self-host user
  than transient pressure during an actual brownout. If it ever bites, the fix
  is a concurrency limit on synchronous embeds, not a shorter timeout.

  Divergences from Voyage's `:query` defaults:

    * **45s, not 5s.** Voyage's 5s guards a remote brownout, where a slow
      response means trouble. Ours guards local queueing, where a slow response
      is the normal cost of concurrent indexing and the vector result is still
      worth waiting for.
    * **`retry: false`, same as Voyage** — and NOT the "retries kept" reasoning
      an earlier cut of this used. That argued `retry_fast_transient?/2` refuses
      to retry a `receive_timeout` so retries could not compound. True for
      `:timeout` ONLY: every other transport error (`:closed`, `:econnreset`,
      `:einval`) returns true, so an Ollama or proxy that accepts a connection
      then resets it late is retried up to `max_retries` at ~45s a go (≈187s
      with backoff) — reinstating the very hang this exists to prevent. One
      attempt keeps the ceiling flat at 45s, which is what the e2e budget nests
      against.

  Explicit caller opts always win over these defaults (tests pass a
  `plug`/`retry_delay`). Public only so the budgets can be unit-tested without a
  live Ollama — the same reason `retry_fast_transient?/2` is public.
  """
  @spec request_defaults(atom()) :: keyword()
  def request_defaults(:query), do: query_defaults()

  def request_defaults(purpose) when purpose in [nil, :index], do: index_defaults()

  # An unrecognized purpose must NOT silently inherit the 120s indexing budget:
  # a typo (`purpose: :querry`) would otherwise reinstate the exact two-minute
  # hang this module exists to prevent, on a user-blocking path. Fall back to
  # the BOUNDED budget (wrong-but-safe) and say so out loud.
  def request_defaults(purpose) do
    Logger.warning(
      "Ollama embed: unknown purpose #{inspect(purpose)} — using the query budget",
      Metadata.with_category(:warning, :search, reason_label: :unknown_embed_purpose)
    )

    query_defaults()
  end

  # `retry: false` — matching Voyage's `:query`, and NOT the earlier reasoning
  # here that retries "stay bounded because retry_fast_transient?/2 refuses to
  # retry a receive_timeout". That is true for `:timeout` ONLY. Every other
  # transport error (:closed, :econnreset, :einval) returns true, so an Ollama —
  # or an LB/proxy in front of it — that accepts a connection and then resets it
  # late is retried up to max_retries, costing ~4 x 45s + backoff ≈ 187s. That
  # blows the client budget, the pytest timeout, and reinstates the exact
  # two-minute user-blocking hang this whole change exists to prevent. One
  # attempt keeps the server-side query ceiling at a flat 45s, which is what the
  # e2e budget nests against.
  defp query_defaults, do: [receive_timeout: 45_000, retry: false]

  defp index_defaults,
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
