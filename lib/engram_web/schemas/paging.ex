defmodule EngramWeb.Schemas.Paging do
  @moduledoc """
  OpenAPI pieces shared by every paged list (`Engram.Pager`): the `cursor` /
  `limit` query parameters and the `next_cursor` response property.
  """
  alias Engram.Batch
  alias OpenApiSpex.Schema

  @doc "Query parameters for `operation/2`'s `:parameters`."
  def parameters do
    [
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Opaque `next_cursor` from the previous page. Omit for the first page. " <>
            "A forged or foreign cursor is a 400 `invalid_cursor`."
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description:
          "Rows per page. Defaults to #{Batch.rest_page_default()}, clamped to #{Batch.page_max()}."
      ]
    ]
  end

  @doc "The `truncated` response property: true when more pages remain."
  def truncated do
    %Schema{
      type: :boolean,
      description:
        "True when this page is not the whole list (`next_cursor` is not null): keep " <>
          "requesting with `cursor` until it is null. Rows are ordered by id, not title."
    }
  end

  @doc "The `next_cursor` response property: null on the last page."
  def next_cursor do
    %Schema{
      type: :string,
      nullable: true,
      description:
        "Pass as `cursor` to get the next page; null when this is the last page. A client " <>
          "that sends no cursor gets the first page only and must follow this to see the rest."
    }
  end
end
