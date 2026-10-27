defmodule Engram.Pager do
  @moduledoc """
  The one place a client-facing list is paged (keyset, never offset).

  * `limit/1` clamps a requested page size; the numbers live in `Engram.Batch`.
  * `encode/2` / `decode/2` make the opaque cursor: a signed term holding a
    scope (`{kind, user_id, vault_id}`) and the last row's sort key. Signed
    with the endpoint secret, so a client cannot forge a position, and bound
    to its scope, so a cursor minted for one tenant, vault or list is refused
    by any other. It carries ids and numbers only, never a path or title.
  * `keyset_gt/4` builds the `(sort, id) > (cursor_sort,
    cursor_id)` row comparison, the only form Postgres can answer as an index
    range on `(.., sort, id)`. An `OR` form walks the feed from the start.
  * `paginate/4` turns `limit + 1` fetched rows into a page and its cursor.

  Callers fetch `limit + 1` rows ordered by the unique `(sort, id)` key.
  """

  alias Engram.Batch

  @salt "engram.pager.v1"
  # A real cursor is ~150 bytes; refuse anything that is not one before
  # spending a signature check on it.
  @max_cursor_bytes 512

  @type scope :: {atom(), term(), term()}

  @doc "Page size for a requested `limit` (nil, integer or numeric string)."
  @spec limit(term()) :: pos_integer()
  def limit(n) when is_integer(n), do: n |> max(1) |> min(Batch.page_max())

  def limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> limit(i)
      _ -> Batch.page_default()
    end
  end

  def limit(_), do: Batch.page_default()

  @doc "The `:cursor` / `:limit` options out of request params (`cursor`, `limit`)."
  @spec opts(map()) :: keyword()
  def opts(params), do: [cursor: params["cursor"], limit: params["limit"]]

  @doc "The scope a cursor is bound to: list kind, owning user and vault."
  @spec scope(atom(), map(), map()) :: scope()
  def scope(kind, user, vault), do: {kind, user.id, vault.id}

  @doc "Signs `key` (the last row's sort key) into an opaque cursor for `scope`."
  @spec encode(scope(), term()) :: String.t()
  def encode(scope, key), do: Plug.Crypto.sign(secret(), @salt, {scope, key})

  @doc """
  `{:ok, nil}` for no cursor, `{:ok, key}` for a valid one minted for `scope`,
  `{:error, :invalid_cursor}` for anything else (forged, truncated, other scope).
  """
  @spec decode(scope(), String.t() | nil) :: {:ok, term()} | {:error, :invalid_cursor}
  def decode(_scope, nil), do: {:ok, nil}
  def decode(_scope, ""), do: {:ok, nil}

  def decode(scope, cursor) when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes do
    case Plug.Crypto.verify(secret(), @salt, cursor) do
      {:ok, {^scope, key}} -> {:ok, key}
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_scope, _cursor), do: {:error, :invalid_cursor}

  @doc """
  Splits `rows` (fetched with `limit + 1`) into `{page, next_cursor}`.
  `next_cursor` is nil on the last page; `key_fun` maps the page's last row to
  the sort key `decode/2` hands back.
  """
  @spec paginate([term()], pos_integer(), scope(), (term() -> term())) ::
          {[term()], String.t() | nil}
  def paginate(rows, limit, scope, key_fun) do
    if length(rows) > limit do
      page = Enum.take(rows, limit)
      {page, encode(scope, key_fun.(List.last(page)))}
    else
      {rows, nil}
    end
  end

  @doc "`(sort, id) > (cursor_sort, cursor_id)` for an ascending feed; `id` is a UUID. Pass the cursor values bare: the macro pins them."
  defmacro keyset_gt(sort, id, cursor_sort, cursor_id) do
    quote do
      fragment(
        "(?, ?) > (?, ?)",
        unquote(sort),
        unquote(id),
        ^unquote(cursor_sort),
        type(^unquote(cursor_id), Ecto.UUID)
      )
    end
  end

  defp secret, do: Application.fetch_env!(:engram, EngramWeb.Endpoint)[:secret_key_base]
end
