defmodule Engram.Embedders.Ollama do
  @moduledoc """
  Ollama embedder adapter for self-hosted inference.
  Uses the /api/embed endpoint (Ollama 0.3+).
  Reads config: OLLAMA_URL (default http://localhost:11434), EMBED_MODEL (nomic-embed-text).
  """

  @behaviour Engram.Embedder

  @default_url "http://localhost:11434"
  @default_model "nomic-embed-text"

  # Index embeds run in Oban workers against an often-remote Ollama endpoint
  # (e.g. FastRaid over the LAN). A single connection-level blip otherwise fails
  # the whole Oban attempt and waits out the job backoff (~30s). Retry the FAST
  # transient failures in-call so a bounced container / momentary 5xx doesn't
  # burn an attempt. Explicit caller opts win (tests pass a `plug`/`retry_delay`).
  defp request_defaults,
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

    {req_opts, _} =
      Keyword.split(opts, [:retry, :max_retries, :retry_delay, :receive_timeout, :plug])

    result =
      Req.post(
        "#{url}/api/embed",
        [json: %{model: model, input: texts}] ++ Keyword.merge(request_defaults(), req_opts)
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
