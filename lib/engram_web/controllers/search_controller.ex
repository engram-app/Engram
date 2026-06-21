defmodule EngramWeb.SearchController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Notes
  alias Engram.Search

  @max_search_limit 50

  operation(:search,
    operation_id: "search",
    summary: "Search notes (vector / keyword / hybrid)",
    description:
      "Searches the current vault and returns one result per matching note (chunk hits are " <>
        "grouped by note, ranked by best chunk score). `mode` selects vector, keyword, or hybrid " <>
        "(default) retrieval, and results may be narrowed by `tags` or `folder`. Setting " <>
        "`cross_vault` searches across all of the user's vaults and requires the Pro plan (403 otherwise).",
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

    opts =
      [
        limit: note_limit,
        cross_vault: cross_vault,
        mode: parse_mode(params["mode"]),
        group_by_note: true
      ]
      |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
      |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))
      |> maybe_put_diversity(params["diversity"])

    case Search.search(user, vault, query, opts) do
      {:ok, results} ->
        # `cross_vault` mode passes nil as the vault filter so id lookup
        # spans all of the user's vaults (matches how the search hits
        # were sourced).
        id_lookup_vault = if cross_vault, do: nil, else: vault

        notes =
          results
          |> Enum.map(fn r ->
            %{
              id: nil,
              path: r.source_path,
              title: r.title || derive_title(r.source_path),
              folder: derive_folder(r.source_path),
              heading_path: r.heading_path,
              snippet: r.text,
              score: r.score,
              match_count: r.match_count
            }
          end)
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

  # When `diversity` is absent or unparseable, return opts unchanged so the
  # SearchProfile default applies. Clamping to [0.0, 1.0] happens downstream
  # in `Engram.Search`.
  defp maybe_put_diversity(opts, nil), do: opts

  defp maybe_put_diversity(opts, raw) do
    case Float.parse(to_string(raw)) do
      {f, ""} -> Keyword.put(opts, :diversity, f)
      _ -> opts
    end
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
