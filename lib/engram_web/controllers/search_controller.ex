defmodule EngramWeb.SearchController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Notes
  alias Engram.Search

  @max_search_limit 50

  # The web client wants N unique notes, but Qdrant ranks chunks. We
  # over-fetch chunks so grouping has enough material to populate the
  # requested number of notes — without this, several top chunks from
  # the same note silently cap the result list well below N.
  @overfetch_factor 4
  @min_overfetch 20

  operation(:search,
    operation_id: "search",
    summary: "Search notes (vector / keyword / hybrid)",
    tags: ["Search"],
    request_body: {"Search query", "application/json", Schemas.SearchRequest, required: true},
    responses: [
      ok: {"Results", "application/json", Schemas.SearchResponse},
      forbidden: {"cross_vault requires Pro", "application/json", Schemas.Error},
      unprocessable_entity: {"Missing query", "application/json", Schemas.Error}
    ]
  )

  def search(conn, %{"query" => query} = params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    note_limit = params["limit"] |> clamp_limit()
    tags = params["tags"]
    folder = params["folder"]
    cross_vault = Map.get(params, "cross_vault", false)

    chunk_limit = max(note_limit * @overfetch_factor, @min_overfetch)

    opts =
      [limit: chunk_limit, cross_vault: cross_vault, mode: parse_mode(params["mode"])]
      |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
      |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))

    case Search.search(user, vault, query, opts) do
      {:ok, results} ->
        # `cross_vault` mode passes nil as the vault filter so id lookup
        # spans all of the user's vaults (matches how the search hits
        # were sourced).
        id_lookup_vault = if cross_vault, do: nil, else: vault

        notes =
          results
          |> group_by_note()
          |> Enum.take(note_limit)
          |> attach_ids(user, id_lookup_vault)

        json(conn, %{results: notes})

      {:error, :feature_not_available} ->
        conn
        |> put_status(403)
        |> json(%{error: "Cross-vault search requires Pro plan"})

      {:error, reason} ->
        require Logger
        Logger.error("Search failed", reason: inspect(reason))

        conn
        |> put_status(500)
        |> json(%{error: "search_failed"})
    end
  end

  def search(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "query is required"})
  end

  defp clamp_limit(nil), do: 5
  defp clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_search_limit)

  defp clamp_limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} -> clamp_limit(int)
      _ -> 5
    end
  end

  defp clamp_limit(_), do: 5

  defp parse_mode("keyword"), do: :keyword
  defp parse_mode("vector"), do: :vector
  defp parse_mode(_), do: :hybrid

  # Collapse per-chunk Qdrant hits into one row per note. The web UI shows
  # a card per note; the MCP path bypasses this and gets raw chunks.
  defp group_by_note(chunks) do
    chunks
    |> Enum.reject(fn c -> is_nil(Map.get(c, :source_path)) end)
    |> Enum.group_by(&Map.fetch!(&1, :source_path))
    |> Enum.map(fn {path, group} ->
      [best | _] = Enum.sort_by(group, & &1.score, :desc)

      %{
        id: nil,
        path: path,
        title: best[:title] || derive_title(path),
        folder: derive_folder(path),
        heading_path: best[:heading_path],
        snippet: best[:text],
        score: best.score,
        match_count: length(group)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  # Batch-resolve note ids for the visible page only — runs once after
  # `Enum.take/2` so we don't pay HMAC + index lookup for over-fetched
  # chunks that get discarded. Hits without a DB id (e.g. a stale Qdrant
  # chunk for a soft-deleted note) keep `id: nil`; the client treats
  # those as legacy-path-only and the LegacyNoteResolver handles
  # routing.
  defp attach_ids([], _user, _vault), do: []

  defp attach_ids(hits, user, vault) do
    paths = Enum.map(hits, & &1.path)
    id_by_path = Notes.note_ids_for_paths(user, vault, paths)
    Enum.map(hits, fn hit -> %{hit | id: Map.get(id_by_path, hit.path)} end)
  end

  defp derive_folder(path) do
    case String.split(path, "/") do
      [_only_file] -> ""
      segments -> segments |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  defp derive_title(path) do
    path
    |> String.split("/")
    |> List.last()
    |> Kernel.||("")
    |> String.replace_suffix(".md", "")
  end
end
