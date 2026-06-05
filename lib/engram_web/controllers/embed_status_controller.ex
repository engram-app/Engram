defmodule EngramWeb.EmbedStatusController do
  use EngramWeb, :controller

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo

  def index(conn, _params) do
    user = conn.assigns.current_user

    {:ok, stats} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note,
          where: n.user_id == ^user.id and is_nil(n.deleted_at) and n.kind == "note",
          select: %{
            total: count(n.id),
            indexed: count(fragment("CASE WHEN ? = ? THEN 1 END", n.embed_hash, n.content_hash)),
            pending:
              count(
                fragment(
                  "CASE WHEN ? IS NULL OR ? != ? THEN 1 END",
                  n.embed_hash,
                  n.embed_hash,
                  n.content_hash
                )
              )
          }
        )
        |> Repo.one!()
      end)

    json(conn, stats)
  end
end
