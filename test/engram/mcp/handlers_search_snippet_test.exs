defmodule Engram.MCP.HandlersSearchSnippetTest do
  # A merged chunk (several chunks in one point, under the per-note cap) holds
  # up to ~30 KB. search_notes prints a hit's text twice (markdown and
  # structuredContent), so it must carry a bounded window, not all of it.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.MCP.Handlers
  alias Engram.QdrantStub

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    QdrantStub.stub_retrieve(bypass)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)
    %{bypass: bypass, user: user, vault: vault}
  end

  # A hit on Big.md whose chunk row holds `text`.
  defp hit(user, vault, text) do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Big.md", title: "Big"})

    %{
      "id" => Engram.Fixtures.insert_chunk!(user, note, Ecto.UUID.generate(), text: text),
      "score" => 0.8
    }
  end

  test "a merged hit prints a window of at most 1,500 chars around the match", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    text =
      Enum.map_join(1..600, "\n\n", fn
        550 -> "Paragraph 550 holds the quixotic finale."
        i -> "Paragraph #{i} of ordinary filler text."
      end)

    point = hit(user, vault, text)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(conn, %{"result" => [point]})))
    end)

    assert {:ok, markdown, %{"results" => [r]}} =
             Handlers.handle("search_notes", user, vault, %{
               "query" => "quixotic finale",
               "diversity" => 0.0
             })

    assert String.length(r["text"]) <= 1_500
    assert r["text"] =~ "quixotic finale"
    assert markdown =~ "quixotic finale"
    assert String.length(markdown) < 2_000
  end
end
