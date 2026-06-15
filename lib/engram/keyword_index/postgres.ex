defmodule Engram.KeywordIndex.Postgres do
  @moduledoc """
  Native-Postgres keyword leg (#595): `tsvector` + `ts_rank_cd` on the primary
  RDS. Zero extra infra. Honest about what it is — this is TF/proximity ranking,
  NOT BM25 (no IDF, no term saturation). At per-user-vault scale that gap is
  small and RRF fusion with the vector leg absorbs the score-scale mismatch.

  Write/read split mirrors the codebase's RLS model:

    * `upsert/1`/`delete/1` run on the default connection role (RLS-bypassing,
      like the chunk inserts in `Engram.Indexing`) — called only from the
      trusted `EmbedNote` worker. Tenant safety comes from the explicit
      `user_id`/`vault_id` written into the row.
    * `search/3` runs inside `Repo.with_tenant/2`, dropping to the `engram_app`
      role so Postgres RLS enforces tenant isolation at the row level, on top of
      the explicit `vault_id` filter.

  Title is weighted `A` and body `B`, so a title hit out-ranks a body-only hit.
  Queries use `websearch_to_tsquery` (handles quotes, `OR`, `-term`) so literal
  user queries like `PADDLE_API_KEY` Just Work.
  """
  @behaviour Engram.KeywordIndex

  import Ecto.Query

  alias Engram.Notes.NoteFts
  alias Engram.Repo

  # `english` is the v1 text-search config (per-language stemming for mixed
  # vaults is deferred, #595). Inlined as a SQL literal, not a bind param —
  # `to_tsvector`/`websearch_to_tsquery` take a `regconfig` (oid), which
  # Postgrex can't encode from a string.

  @impl Engram.KeywordIndex
  def upsert(%{id: note_id, user_id: user_id, vault_id: vault_id} = note) do
    title = note.title || ""
    content = note.content || ""

    sql = """
    INSERT INTO notes_fts (note_id, user_id, vault_id, search_vector, created_at, updated_at)
    VALUES ($1, $2, $3,
      setweight(to_tsvector('english', $4), 'A') || setweight(to_tsvector('english', $5), 'B'),
      now(), now())
    ON CONFLICT (note_id) DO UPDATE
      SET search_vector = EXCLUDED.search_vector,
          vault_id = EXCLUDED.vault_id,
          updated_at = now()
    """

    case Repo.query(sql, [
           dump_uuid(note_id),
           dump_uuid(user_id),
           dump_uuid(vault_id),
           title,
           content
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Engram.KeywordIndex
  def delete(note_id) do
    Repo.query!("DELETE FROM notes_fts WHERE note_id = $1", [dump_uuid(note_id)])
    :ok
  end

  # Postgrex binds a uuid column param as the 16-byte binary, not the text form.
  defp dump_uuid(id), do: id |> to_string() |> Ecto.UUID.dump!()

  @impl Engram.KeywordIndex
  def search(query, %{user_id: user_id} = scope, opts) do
    limit = Keyword.get(opts, :limit, 5)
    vault_id = Map.get(scope, :vault_id)

    {:ok, rows} =
      Repo.with_tenant(to_string(user_id), fn ->
        NoteFts
        |> where(
          [f],
          fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^query)
        )
        |> maybe_vault(vault_id)
        |> order_by(
          [f],
          desc: fragment("ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))", ^query)
        )
        |> limit(^limit)
        |> select(
          [f],
          {f.note_id,
           fragment("ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))", ^query)}
        )
        |> Repo.all()
      end)

    {:ok, rows}
  end

  defp maybe_vault(query, nil), do: query
  defp maybe_vault(query, vault_id), do: where(query, [f], f.vault_id == ^vault_id)
end
