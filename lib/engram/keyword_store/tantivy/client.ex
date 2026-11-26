defmodule Engram.KeywordStore.Tantivy.Client do
  @moduledoc """
  HTTPS client of the kwsearch service (`native/kwsearch`).

  Config (`:engram, :kwsearch`, from env in `config/runtime.exs`):

    * `:url` - `https://host:port`
    * `:ca_file` - CA bundle the listener's certificate must chain to
      (security F6: `verify: :verify_peer`, never plain HTTP in prod)
    * `:token_keys` - `[current, next]` HMAC keys; requests are signed with
      the first (`Engram.KeywordStore.Tantivy.Token`)
    * `:timeout_ms` - receive timeout of a search (default 1000)

  The tenant goes in the signed token only: the body carries terms, the
  generation, the limit and the note id lists, which go compact (base64 of
  the raw 16-byte ids, roadmap P2 task 4e). Errors come back as bounded
  reasons; a response body is never returned or logged (F15).
  """

  alias Engram.KeywordStore.Tantivy.Token
  alias Engram.ServiceConfig

  @gen 1

  @spec search(String.t(), [String.t()], [non_neg_integer()], keyword()) ::
          {:ok, [%{qdrant_id: String.t(), score: float()}]} | {:error, term()}
  def search(user_id, vault_ids, terms, search_opts) do
    body =
      %{gen: @gen, terms: terms, limit: Keyword.get(search_opts, :limit, 5)}
      |> put_scope(Keyword.get(search_opts, :note_scope))

    token = Token.search(user_id, vault_ids, signing_key())

    with {:ok, req} <- req() do
      req |> Req.post(url: "/search", json: body, auth: {:bearer, token}) |> hits()
    end
  end

  defp hits(response) do
    case response do
      {:ok, %Req.Response{status: 200, body: %{"hits" => hits}}} ->
        {:ok, for([id, score] <- hits, do: %{qdrant_id: id, score: score / 1})}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:kwsearch_status, status}}

      {:error, %{__exception__: true} = e} ->
        {:error, {:kwsearch_transport, e.__struct__}}
    end
  end

  @doc "The highest `(xid, seq)` every shard has applied and committed."
  @spec cursor() :: {:ok, {non_neg_integer(), integer()}} | {:error, term()}
  def cursor do
    case state() do
      {:ok, %{"xid" => xid, "seq" => seq}} when is_binary(xid) and is_integer(seq) ->
        {:ok, {String.to_integer(xid), seq}}

      {:ok, _} ->
        {:error, :kwsearch_bad_body}

      error ->
        error
    end
  end

  @doc """
  The index epoch and whether it is still rebuilding (a new index, or one
  after a feed gap): the reconcile's full-load target.
  """
  @spec epoch() :: {:ok, %{id: String.t(), rebuilding: boolean()}} | {:error, term()}
  def epoch do
    case state() do
      {:ok, %{"epoch" => id, "rebuilding" => rebuilding}}
      when is_binary(id) and is_boolean(rebuilding) ->
        {:ok, %{id: id, rebuilding: rebuilding}}

      {:ok, _} ->
        {:error, :kwsearch_bad_body}

      error ->
        error
    end
  end

  defp state do
    with :ok <- configured(),
         {:ok, req} <- req() do
      req |> Req.get(url: "/cursor", auth: {:bearer, Token.ops(signing_key())}) |> body()
    end
  end

  @doc """
  One user's bulk batch (`Engram.KeywordStore.Tantivy.Bulk`): `read_at` is
  the unix second the rows were read under their note locks; kwsearch refuses
  a batch older than an hour (`{:error, {:kwsearch_status, 409}}`).
  """
  @spec bulk(String.t(), integer(), [map()]) :: {:ok, map()} | {:error, term()}
  def bulk(user_id, read_at, notes) do
    with :ok <- configured(),
         {:ok, req} <- req() do
      req
      |> Req.post(
        url: "/bulk",
        json: %{gen: @gen, read_at: read_at, notes: notes},
        auth: {:bearer, Token.bulk(user_id, signing_key())},
        receive_timeout: 60_000
      )
      |> body()
    end
  end

  @doc """
  One page of the user's indexed notes: `[{note_id, vault_id, doc_count}]`
  by note id, after `after` (nil: from the start).
  """
  @spec notes(String.t(), String.t() | nil, pos_integer()) ::
          {:ok, [{String.t(), String.t(), non_neg_integer()}]} | {:error, term()}
  def notes(user_id, after_id, limit) do
    body =
      if after_id,
        do: %{gen: @gen, after: after_id, limit: limit},
        else: %{gen: @gen, limit: limit}

    with :ok <- configured(),
         {:ok, req} <- req(),
         {:ok, %{"notes" => notes}} <-
           req
           |> Req.post(
             url: "/notes",
             json: body,
             auth: {:bearer, Token.bulk(user_id, signing_key())},
             receive_timeout: 30_000
           )
           |> body() do
      {:ok, for([n, v, c] <- notes, do: {n, v, c})}
    else
      {:ok, _} -> {:error, :kwsearch_bad_body}
      error -> error
    end
  end

  @doc "Tells kwsearch every user is loaded for `epoch` (it may then serve)."
  @spec rebuilt(String.t()) :: :ok | {:error, term()}
  def rebuilt(epoch) do
    with :ok <- configured(),
         {:ok, req} <- req(),
         {:ok, _} <-
           req
           |> Req.post(
             url: "/rebuilt",
             json: %{epoch: epoch},
             auth: {:bearer, Token.ops(signing_key())}
           )
           |> body(),
         do: :ok
  end

  # A 200's decoded body; any other status or a transport error as a
  # bounded reason (never the body, F15).
  defp body(response) do
    case response do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:kwsearch_status, status}}

      {:error, %{__exception__: true} = e} ->
        {:error, {:kwsearch_transport, e.__struct__}}
    end
  end

  # Raw 16-byte ids, base64: 219 KB vs 400 KB of JSON strings at 10,240 ids.
  @doc false
  def encode_ids(ids),
    do: ids |> Enum.map(&raw_uuid/1) |> IO.iodata_to_binary() |> Base.encode64()

  defp put_scope(body, {:ids, ids}), do: Map.put(body, :include_b64, encode_ids(ids))
  defp put_scope(body, {:exclude, ids}), do: Map.put(body, :exclude_b64, encode_ids(ids))
  defp put_scope(body, _none), do: body

  defp raw_uuid(<<_::128>> = raw), do: raw
  defp raw_uuid(id), do: Ecto.UUID.dump!(to_string(id))

  defp config, do: ServiceConfig.get(:kwsearch, [])

  # The trim also runs after the feed is rolled back, when kwsearch may no
  # longer be configured at all.
  defp configured do
    cfg = config()

    if Keyword.has_key?(cfg, :url) and Keyword.get(cfg, :token_keys, []) != [],
      do: :ok,
      else: {:error, :kwsearch_not_configured}
  end

  defp signing_key do
    case Keyword.get(config(), :token_keys, []) do
      [key | _] when is_binary(key) and key != "" -> key
      _ -> raise ArgumentError, "kwsearch :token_keys is not configured"
    end
  end

  # Plain HTTP only where `:allow_http` says so (the test stub): the hop
  # carries the signed token, query dims and hit ids (security F6).
  defp req do
    cfg = config()
    url = Keyword.fetch!(cfg, :url)

    if URI.parse(url).scheme == "https" or Keyword.get(cfg, :allow_http, false),
      do: {:ok, build_req(cfg)},
      else: {:error, :kwsearch_plain_http}
  end

  defp build_req(cfg) do
    Req.new(
      base_url: Keyword.fetch!(cfg, :url),
      receive_timeout: Keyword.get(cfg, :timeout_ms, 1_000),
      retry: false,
      connect_options: connect_options(cfg)
    )
    |> Req.merge(ServiceConfig.get(:kwsearch_req_options, []))
  end

  defp connect_options(cfg) do
    case Keyword.get(cfg, :ca_file) do
      nil ->
        [protocols: [:http1]]

      ca ->
        [
          protocols: [:http1],
          transport_opts: [
            verify: :verify_peer,
            cacertfile: ca,
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
    end
  end
end
