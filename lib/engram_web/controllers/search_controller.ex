defmodule EngramWeb.SearchController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Notes
  alias Engram.Pager
  alias Engram.Search
  alias Engram.Search.NoteFilter

  @max_search_limit 50

  # `Engram.Search.FieldFilters.error()`: a bad `fields` filter is the caller's.
  @field_errors [
    :unknown_field,
    :field_not_indexed,
    :reserved_field,
    :invalid_field_filter,
    :too_many_field_filters
  ]

  operation(:search,
    operation_id: "search",
    summary: "Search notes (vector / keyword / hybrid)",
    description:
      "Searches the current vault and returns one result per matching note (chunk hits are " <>
        "grouped by note, ranked by best chunk score). `mode` selects vector, keyword, or hybrid " <>
        "(default) retrieval, and results may be narrowed by `tags` or `folder`. Setting " <>
        "`cross_vault` searches across all of the user's vaults and requires the Pro plan (403 otherwise). " <>
        "With a blank `query` and at least one filter, lists the matching notes of the current " <>
        "vault newest first instead (no ranking, no search budget, `cursor` / `next_cursor` paging).",
    tags: ["Search"],
    request_body: {"Search query", "application/json", Schemas.SearchRequest, required: true},
    responses: [
      ok: {"Results", "application/json", Schemas.SearchResponse},
      forbidden: {"cross_vault requires Pro", "application/json", Schemas.Error},
      unprocessable_entity: {"Missing query", "application/json", Schemas.Error}
    ]
  )

  def search(conn, params) do
    query = params["query"]
    blank? = not is_binary(query) or String.trim(query) == ""

    case Search.filter_opts(params) do
      {_filters, [param | _]} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: invalid_param(param)})

      {filters, []} ->
        cond do
          blank? and NoteFilter.any?(filters) -> filter_only(conn, params, filters)
          is_binary(query) -> query_search(conn, params, query, filters)
          true -> conn |> put_status(422) |> json(%{error: "query is required"})
        end
    end
  end

  defp invalid_param(param) do
    if param in Enum.map(Search.date_params(), &to_string/1),
      do: "invalid ISO 8601 datetime in #{param}",
      else: "invalid #{param}"
  end

  defp query_search(conn, params, query, filters) do
    note_limit = params["limit"] |> clamp_limit()
    cross_vault = parse_bool(params["cross_vault"])

    opts =
      [
        limit: note_limit,
        cross_vault: cross_vault,
        mode: Search.parse_mode(params["mode"]),
        group_by_note: true,
        surface: EngramWeb.RequestMeta.surface(conn.assigns)
      ]
      |> Kernel.++(filters)
      |> maybe_put_diversity(params["diversity"])
      |> then(&if(cross_vault, do: narrow_to_vault_scope(&1, conn), else: &1))

    do_search(
      conn,
      conn.assigns.current_user,
      conn.assigns.current_vault,
      query,
      note_limit,
      opts
    )
  end

  # Filters with no query (#2083): answered in Postgres, newest first, keyset
  # paged (`cursor` / `limit`), no embed and no search budget. One vault.
  defp filter_only(conn, params, filters) do
    if parse_bool(params["cross_vault"]) do
      conn |> put_status(422) |> json(%{error: "cross_vault needs a query"})
    else
      user = conn.assigns.current_user

      case NoteFilter.page(user, conn.assigns.current_vault, filters, Pager.rest_opts(params)) do
        {:ok, %{notes: notes, next_cursor: next}} ->
          results =
            Enum.map(notes, fn n ->
              %{
                id: n.id,
                path: n.path,
                title: n.title || derive_title(n.path),
                folder: n.folder || derive_folder(n.path),
                heading_path: nil,
                snippet: "",
                score: 0,
                match_count: 0
              }
            end)

          json(conn, Map.merge(%{results: results}, Pager.page_meta(next)))

        {:error, :invalid_cursor} ->
          conn |> put_status(422) |> json(%{error: "invalid cursor"})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: Search.input_error_message(reason)})
      end
    end
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

  # `?cross_vault=false` arrives as the STRING "false", which is truthy in
  # Elixir — so reading the param raw turned an explicit opt-OUT into an
  # opt-IN, and then 403'd the caller on the Pro entitlement gate for a
  # feature they were trying not to use. No CastAndValidate plug runs on this
  # route, so a JSON body delivers a real boolean and a query string a binary;
  # both land here. Cast at the boundary and everything downstream keeps its
  # bare-truthiness reads.
  defp parse_bool(true), do: true
  defp parse_bool("true"), do: true
  defp parse_bool(_), do: false

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

  # A cross-vault search deliberately searches PAST the request's single vault,
  # so VaultPlug's check does not bound it. Narrow to what the CREDENTIAL may
  # reach. `:all` is genuinely unrestricted and must not get a filter — adding
  # one there would break legitimate Pro cross-vault search; anything else
  # becomes an any-match Qdrant filter over exactly the permitted set.
  #
  # Only called on the cross-vault path: a single-vault search is already bound
  # by VaultPlug's check on X-Vault-ID, `put_vault_filter/3` ignores
  # `vault_ids` whenever a concrete vault is passed, and VaultPlug has already
  # paid for this exact scope — so calling it unconditionally bought a second
  # `api_key_vaults` SELECT on every plain search for a value that is inert.
  defp narrow_to_vault_scope(opts, conn) do
    case Engram.Permissions.vault_scope(conn) do
      :all ->
        opts

      # Resolved against the user's vaults, not read off the scope: a vault
      # reached through the new-vaults policy (#174) is listed nowhere in it.
      scope ->
        vaults =
          Engram.Permissions.filter(scope, Engram.Vaults.list_vaults(conn.assigns.current_user))

        Keyword.put(opts, :vault_ids, Enum.map(vaults, & &1.id))
    end
  end

  # Batch-resolve note ids for the visible page only — runs after `Enum.take/2`
  # so we don't pay HMAC + index lookup for over-fetched chunks that get
  # discarded. Results without a DB id (e.g. a stale Qdrant chunk for a
  # soft-deleted note) keep `id: nil`; the client treats those as
  # legacy-path-only and the LegacyNoteResolver handles routing.
  #
  # Keyed on {vault_id, path} using each RESULT's own vault, not one ambient
  # vault. The cross-vault path used to pass `vault: nil`, which makes
  # `Notes.note_ids_for_paths/3` drop its vault predicate and match `path_hmac`
  # across EVERY vault the user owns — so a path living in two vaults
  # (`Inbox.md`, a daily note, any convention-driven filename) resolved to
  # whichever row the reduce saw last. That could be a vault the credential was
  # scoped away from: not a content leak (follow-up reads are vault-scoped) but
  # a wrong id and a UUID from outside the very filter this path applies.
  # Qdrant returns `vault_id` on every hit and `collapse_to_notes` keys on it,
  # so the correct vault is already in hand. One query per distinct vault on the
  # page — exactly one for a single-vault search, as before.
  #
  # Rehydration already read each hit's note row, so a result normally
  # carries its `note_id` and costs no lookup; only results without one (a
  # payload-only hit) are resolved here.
  defp note_ids_by_vault(_user, []), do: %{}

  defp note_ids_by_vault(user, results) do
    {known, unknown} = Enum.split_with(results, &is_binary(Map.get(&1, :note_id)))
    ids = Map.new(known, &{{&1.vault_id, &1.source_path}, &1.note_id})

    unknown
    |> Enum.group_by(& &1.vault_id, & &1.source_path)
    |> Enum.reject(fn {vault_id, _paths} -> is_nil(vault_id) end)
    |> Enum.flat_map(fn {vault_id, paths} ->
      # `note_ids_for_paths/3` reads only the vault's `id`.
      user
      |> Notes.note_ids_for_paths(%{id: vault_id}, paths)
      |> Enum.map(fn {path, id} -> {{vault_id, path}, id} end)
    end)
    |> Map.new()
    |> Map.merge(ids)
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

  defp do_search(conn, user, vault, query, note_limit, opts) do
    case Search.search(user, vault, query, opts) do
      {:error, :search_cap_exceeded, limit} ->
        EngramWeb.LimitResponse.halt(
          conn,
          "ai_searches_per_day_exceeded",
          :ai_searches_per_day,
          limit,
          limit
        )

      {:ok, results} ->
        results = Enum.take(results, note_limit)
        ids = note_ids_by_vault(user, results)

        notes =
          results
          |> Enum.map(fn r ->
            %{
              id: Map.get(ids, {r.vault_id, r.source_path}),
              path: r.source_path,
              title: r.title || derive_title(r.source_path),
              folder: derive_folder(r.source_path),
              heading_path: r.heading_path,
              snippet: r.text,
              score: r.score,
              match_count: r.match_count
            }
          end)

        json(conn, %{results: notes})

      {:error, :feature_not_available} ->
        conn
        |> put_status(403)
        |> json(%{error: "Cross-vault search requires Pro plan"})

      {:error, reason}
      when reason in [:query_too_long, :too_many_tags, :folder_subtree_too_large] or
             (is_tuple(reason) and elem(reason, 0) in @field_errors) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: Search.input_error_message(reason)})

      {:error, reason} ->
        require Logger

        Logger.error(
          "Search failed",
          Engram.Logger.Metadata.with_category(:error, :search,
            reason: Engram.Logger.Metadata.safe_reason(reason)
          )
        )

        conn
        |> put_status(500)
        |> json(%{error: "search_failed"})
    end
  end
end
