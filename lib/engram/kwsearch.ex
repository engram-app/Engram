defmodule Engram.Kwsearch do
  @moduledoc """
  POC client for kwsearch, the Tantivy keyword service (native/kwsearch,
  search storage roadmap R3). Not wired into search: this is the integration
  shape only (branch poc/kwsearch).

  Plain HTTP/1.1 with keep-alive through Req's default Finch pool, the same
  transport and fail-fast options as `Engram.Vector.Qdrant.req_opts(:search)`.
  Terms are the per-user HMAC dims from `Engram.Native.encode_query_nif/3`;
  the service never sees the key or the query text.

  Note-id filters go as base64 of the concatenated 16-byte ids
  (`include_b64` / `exclude_b64`), not JSON UUID strings. Measured at the
  10,240-id cap: 219 KB of body instead of 400 KB, and 2.3 ms to encode from
  raw 16-byte ids vs 6.5 ms for JSON strings (p50). Encoding from STRING ids
  costs ~20 ms (`Ecto.UUID.dump!/1` per id), so the filter query should hand
  over raw `uuid` binaries (no Ecto cast); both are accepted here.

  Config: `config :engram, Engram.Kwsearch, url: ..., secret: ...`.
  """

  # NoteFilter's id cap, and Qdrant.max_page() for the :too_wide oversample.
  @max_ids 10_240
  @max_limit 4_096

  @type hit :: {Ecto.UUID.t(), float()}

  @doc """
  Top `limit` chunks of `user_id`'s `vault_ids` for hashed `terms`.

  Options: `:include` / `:exclude` (note ids, at most #{@max_ids} each),
  `:limit` (default 40, at most #{@max_limit}), `:receive_timeout`.
  """
  @spec search(Ecto.UUID.t(), [Ecto.UUID.t()], [non_neg_integer()], keyword()) ::
          {:ok, [hit()]} | {:error, term()}
  def search(user_id, vault_ids, terms, opts \\ []) do
    include = Keyword.get(opts, :include)
    exclude = Keyword.get(opts, :exclude, [])
    limit = Keyword.get(opts, :limit, 40)

    cond do
      length(include || []) > @max_ids or length(exclude) > @max_ids ->
        {:error, :too_many_ids}

      limit < 1 or limit > @max_limit ->
        {:error, :bad_limit}

      true ->
        body =
          %{user: user_id, vaults: vault_ids, terms: terms, limit: limit}
          |> put_ids(:include_b64, include)
          |> put_ids(:exclude_b64, if(exclude == [], do: nil, else: exclude))

        request(body, Keyword.get(opts, :receive_timeout, 2_000))
    end
  end

  @doc "16-byte ids concatenated, base64: the service's compact id encoding."
  @spec encode_ids([Ecto.UUID.t() | <<_::128>>]) :: String.t()
  def encode_ids(ids), do: ids |> Enum.map(&raw/1) |> IO.iodata_to_binary() |> Base.encode64()

  defp raw(<<_::128>> = id), do: id
  defp raw(id), do: Ecto.UUID.dump!(id)

  defp put_ids(body, _key, nil), do: body
  defp put_ids(body, key, ids), do: Map.put(body, key, encode_ids(ids))

  defp request(body, timeout) do
    cfg = Application.get_env(:engram, __MODULE__, [])

    case Req.post(Keyword.fetch!(cfg, :url) <> "/search",
           json: body,
           headers: [{"authorization", "Bearer " <> Keyword.fetch!(cfg, :secret)}],
           receive_timeout: timeout,
           retry: false,
           connect_options: [protocols: [:http1]]
         ) do
      {:ok, %{status: 200, body: %{"hits" => hits}}} ->
        {:ok, Enum.map(hits, fn [id, score] -> {id, score} end)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, e} ->
        {:error, e}
    end
  end
end
