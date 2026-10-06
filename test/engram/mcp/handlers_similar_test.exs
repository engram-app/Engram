defmodule Engram.MCP.HandlersSimilarTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.MCP.Handlers
  alias Engram.Notes
  alias Engram.Notes.Chunk

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    expect(Engram.MockEmbedder, :embed_texts, 0, fn _t, _o ->
      flunk("similar_to must not embed")
    end)

    %{bypass: bypass, user: user, vault: vault}
  end

  defp note_with_points(user, vault, path, n, embedded?) do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{
          "path" => path,
          "content" => "# #{path}\n\nbody",
          "mtime" => 1.0
        },
        actor: "api"
      )

    ids =
      for pos <- 0..(n - 1)//1 do
        id = Ecto.UUID.generate()

        {:ok, _} =
          Engram.Repo.with_tenant(user.id, fn ->
            %Chunk{}
            |> Chunk.changeset(%{
              note_id: note.id,
              user_id: user.id,
              vault_id: vault.id,
              position: pos,
              char_start: 0,
              char_end: 4,
              qdrant_point_id: id
            })
            |> Engram.Repo.insert!()
          end)

        id
      end

    if embedded? do
      Engram.Repo.update_all(
        from(x in Engram.Notes.Note, where: x.id == ^note.id),
        [set: [dense_indexed_hash: "h"]],
        skip_tenant_check: true
      )
    end

    ids
  end

  defp hit(user, vault, point_id) do
    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: "body", title: "O", heading_path: "O"},
        user,
        "engram_notes",
        point_id
      )

    %{
      "id" => point_id,
      "score" => 0.8,
      "payload" => %{
        "text" => enc.text,
        "title" => enc.title,
        "heading_path" => enc.heading_path,
        "text_nonce" => enc.text_nonce,
        "title_nonce" => enc.title_nonce,
        "heading_path_nonce" => enc.heading_path_nonce,
        "aad_version" => enc.aad_version,
        "user_id" => to_string(user.id),
        "vault_id" => to_string(vault.id)
      }
    }
  end

  defp respond(conn, points) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => %{"points" => points}}))
  end

  test "recommends from the source's stored points and excludes them", %{
    bypass: bypass,
    user: u,
    vault: v
  } do
    s_ids = note_with_points(u, v, "S.md", 2, true)
    [o_id] = note_with_points(u, v, "O.md", 1, true)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["using"] == "dense"
      assert Enum.sort(json["query"]["recommend"]["positive"]) == Enum.sort(s_ids)
      assert json["query"]["recommend"]["strategy"] == "average_vector"
      assert [%{"has_id" => excluded}] = json["filter"]["must_not"]
      assert Enum.sort(excluded) == Enum.sort(s_ids)

      assert %{"key" => "vault_id", "match" => %{"value" => to_string(v.id)}} in json["filter"][
               "must"
             ]

      # Review Focus (d): the tenant filter, not just the excluded ids, is what
      # keeps a recommend call from ever crossing user/vault boundaries.
      assert %{"key" => "user_id", "match" => %{"value" => to_string(u.id)}} in json["filter"][
               "must"
             ]

      respond(conn, [hit(u, v, o_id)])
    end)

    assert {:ok, _text, %{"results" => [r]}} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md", "query" => nil})

    assert r["source_path"] == "O.md"
  end

  # Review Focus (a)-(c): RLS proves nothing in this suite (superuser
  # connection). The real boundary is `similar_source/3` resolving the path
  # through `Notes.scoped/2`'s explicit `user_id AND vault_id` filter. None of
  # these register a Bypass expectation: the right outcome is that Qdrant is
  # never called.
  test "cross-user: another user's note by the same path is invisible", %{user: u, vault: v} do
    {:ok, other_user} = Engram.Fixtures.user_with_dek_fixture()
    other_vault = insert(:vault, user: other_user)
    note_with_points(other_user, other_vault, "S.md", 1, true)

    assert {:error, "Note not found: S.md"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md"})
  end

  test "wrong vault: a note in another vault owned by the same user is invisible", %{
    user: u,
    vault: v
  } do
    other = insert(:vault, user: u)
    note_with_points(u, other, "S.md", 1, true)

    assert {:error, "Note not found: S.md"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md"})
  end

  test "credential subset: cross-vault search only sees the vaults it was given", %{
    user: u,
    vault: v
  } do
    other = insert(:vault, user: u)
    note_with_points(u, other, "S.md", 1, true)

    assert {:error, "Note not found: S.md"} =
             Handlers.handle("search_notes", u, {:cross_vault, [v]}, %{"similar_to" => "S.md"})
  end

  test "does not spend the search budget", %{bypass: bypass, user: u, vault: v} do
    note_with_points(u, v, "S.md", 1, true)
    insert(:user_limit_override, user: u, key: "ai_searches_per_day", value: %{"v" => 0})
    assert {:error, :search_cap_exceeded, 0} = Engram.Search.search(u, v, "anything")

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", &respond(&1, []))

    assert {:ok, "No results found.", %{"results" => []}} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md"})
  end

  # Review Focus 2: no Bypass expectation, so any Qdrant call fails the test.
  test "a note with no dense vectors is a fixable error, not a search", %{user: u, vault: v} do
    note_with_points(u, v, "Sparse.md", 2, false)
    note_with_points(u, v, "Empty.md", 0, true)

    for path <- ["Sparse.md", "Empty.md"] do
      assert {:error, msg} = Handlers.handle("search_notes", u, v, %{"similar_to" => path})
      assert msg =~ "#{path} has no stored embedding yet"
      assert msg =~ "use query"
    end
  end

  test "query and similar_to together, a blank similar_to, and a missing note are fixable",
       %{user: u, vault: v} do
    assert {:error, "Pass query or similar_to, not both"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md", "query" => "x"})

    assert {:error, "similar_to must be a note path"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => " "})

    assert {:error, "Note not found: Gone.md"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "Gone.md"})
  end

  test "cross-vault: the source is found in its one vault and results span all", %{
    bypass: bypass,
    user: u,
    vault: v
  } do
    other = insert(:vault, user: u)
    note_with_points(u, v, "S.md", 1, true)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      must = Jason.decode!(body)["filter"]["must"]

      assert %{"key" => "vault_id", "match" => %{"any" => ids}} =
               Enum.find(must, &(&1["key"] == "vault_id"))

      assert Enum.sort(ids) == Enum.sort([to_string(v.id), to_string(other.id)])
      respond(conn, [])
    end)

    assert {:ok, _, _} =
             Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{
               "similar_to" => "S.md"
             })
  end

  test "cross-vault: a path held by two vaults asks for vault_id", %{user: u, vault: v} do
    other = insert(:vault, user: u)
    note_with_points(u, v, "S.md", 1, true)
    note_with_points(u, other, "S.md", 1, true)

    assert {:error, msg} =
             Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{
               "similar_to" => "S.md"
             })

    assert msg =~ "S.md exists in 2 vaults"
    assert msg =~ "pass vault_id"
  end

  for status <- [400, 404] do
    test "a Qdrant #{status} on recommend is the fixable not_embedded error, not an outage",
         %{bypass: bypass, user: u, vault: v} do
      note_with_points(u, v, "S.md", 1, true)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        Plug.Conn.resp(conn, unquote(status), "")
      end)

      assert {:error, msg} = Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md"})
      assert msg =~ "S.md has no stored embedding yet"
      assert msg =~ "use query"
    end
  end

  test "drops a stray hit that belongs to the source note itself", %{
    bypass: bypass,
    user: u,
    vault: v
  } do
    s_ids = note_with_points(u, v, "S.md", 2, true)
    [o_id] = note_with_points(u, v, "O.md", 1, true)
    [stray_id | _] = s_ids

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      # A stray point still tagged to S.md's own chunks — as if a failed
      # delete_points_for_note left it behind and Qdrant's must_not exclusion
      # somehow missed it. The grouped result must still not include S.md.
      respond(conn, [hit(u, v, stray_id), hit(u, v, o_id)])
    end)

    assert {:ok, _text, %{"results" => results}} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md"})

    assert Enum.map(results, & &1["source_path"]) == ["O.md"]
  end

  test "folder, tags, and limit reach the Qdrant request", %{bypass: bypass, user: u, vault: v} do
    note_with_points(u, v, "S.md", 1, true)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      # Grouped (group_by_note: true) always over-fetches the candidate pool
      # (max(limit * 4, profile default 20)); limit=6 -> 24.
      assert json["limit"] == 24
      must = json["filter"]["must"]
      assert Enum.any?(must, &(&1["key"] == "folder_hmac"))
      assert Enum.any?(must, &(&1["key"] == "tags_hmac"))
      respond(conn, [])
    end)

    assert {:ok, _, _} =
             Handlers.handle("search_notes", u, v, %{
               "similar_to" => "S.md",
               "folder" => "Projects",
               "tags" => ["x"],
               "limit" => 6
             })
  end

  test "schema declares similar_to" do
    {:ok, tool} = Engram.MCP.Tools.get("search_notes")
    assert tool.inputSchema["properties"]["similar_to"]["type"] == "string"
  end
end
