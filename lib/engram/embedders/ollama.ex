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
  # (e.g. FastRaid over the LAN). A single Req.TransportError otherwise fails
  # the whole Oban attempt and waits out the job backoff (~30s), which can miss
  # a downstream index probe (e2e test_32 flake). Mirror the Voyage index
  # defaults: retry transient transport errors + 5xx a few times within the
  # call. Explicit caller opts win (tests pass a `plug`/`retry_delay: 0`).
  @request_defaults [receive_timeout: 120_000, retry: :transient, max_retries: 3]

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
        [json: %{model: model, input: texts}] ++ Keyword.merge(@request_defaults, req_opts)
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
