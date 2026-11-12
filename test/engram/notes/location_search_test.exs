defmodule Engram.Notes.LocationSearchTest do
  # S3 read switch (Engram#2523): a search hit shows its note where the
  # folder row and the name put it (`Notes.search_hits_by_qdrant_points/2`
  # through `Engram.Notes.Location.put_paths/3`), with the folder chain read
  # in the hits' own tenant transaction.
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.{Crypto, DataMigrations, Indexing, Notes, ServiceConfig}
  alias Engram.Folders.Rows
  alias Engram.Notes.Chunk

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "Health/Iron.md", "content" => "# Iron\n\nFerritin is low."},
        actor: "api"
      )

    {:ok, _} = Indexing.index_note(note, vault)
    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)
    %{user: user, vault: vault, note: note}
  end

  defp hit_paths(user, note) do
    ids =
      Repo.all(from(c in Chunk, where: c.note_id == ^note.id, select: c.qdrant_point_id),
        skip_tenant_check: true
      )
      |> Enum.map(&to_string/1)

    assert ids != []
    {:ok, hits} = Notes.search_hits_by_qdrant_points(user, ids)
    hits |> Map.values() |> Enum.map(& &1.source_path) |> Enum.uniq()
  end

  test "a hit carries the path derived from its folder row", %{user: u, vault: v, note: note} do
    {:ok, dek} = Crypto.get_dek(u)
    {:ok, fk} = Crypto.dek_filter_key(u)
    id = Repo.with_tenant!(u.id, fn -> Rows.ids_by_path(u, v.id, ["Health"]) end)["Health"]
    {ct, nonce} = Rows.encrypt_name(dek, id, "Body")

    Repo.query!(
      "UPDATE folders SET name_ciphertext = $2, name_nonce = $3, name_hmac = $4 WHERE id = $1",
      [Ecto.UUID.dump!(id), ct, nonce, Rows.name_hmac(fk, "Body")]
    )

    assert hit_paths(u, note) == ["Health/Iron.md"]

    :ok = DataMigrations.mark_done("note_name", 1)
    Engram.Cache.clear_local(:note_name)
    assert hit_paths(u, note) == ["Body/Iron.md"]
  end
end
