defmodule Engram.IndexingExclusionsTest do
  @moduledoc """
  Embed less: `.canvas` and `.base` notes are keyword-only (no Voyage calls,
  no metered tokens), and an Excalidraw note's drawing data leaves the index
  while its text elements stay searchable and embedded.
  """
  use Engram.DataCase, async: true

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.Notes
  alias Engram.Parsers.Markdown
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  @canvas ~s({"nodes":[{"id":"n1","type":"text","text":"Zanzibar launch plan"}],"edges":[]})
  @base "views:\n  - type: table\n    name: Zanzibar tasks\n"

  @excalidraw """
  ---
  excalidraw-plugin: parsed
  ---

  # Excalidraw Data

  ## Text Elements
  Zanzibar architecture sketch ^abc12345

  %%
  ## Drawing
  ```json
  {"type":"rectangle","x":1,"y":2,"id":"qqrect"}
  ```
  %%
  """

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    test_pid = self()

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test_pid, {:embedded, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put_note(ctx, path, content) do
    {:ok, note} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, ctx.user)
    note
  end

  defp has_dim?(point, user, token) do
    {:ok, key} = Crypto.dek_filter_key(user)
    %{indices: indices} = QdrantSparse.unpack(point.vector["keyword"])
    QdrantSparse.dim(key, token) in indices
  end

  for {path, content} <- [{"Board.canvas", @canvas}, {"Tasks.base", @base}] do
    test "#{path} is keyword-only: no embed, no metered tokens", ctx do
      note = put_note(ctx, unquote(path), unquote(content))
      test_pid = self()

      reserve = fn tokens ->
        send(test_pid, {:reserved, tokens})
        true
      end

      assert Enum.all?(Markdown.parse(note.content, note.path), &(&1.kind == "data"))

      assert {:ok, prepared} =
               Indexing.prepare_index(note, ctx.vault, ctx.user, reserve_tokens: reserve)

      refute_received {:embedded, _}
      refute_received {:reserved, _}
      assert prepared.embedded_bytes == 0
      assert [_ | _] = prepared.qdrant_points
      refute Enum.any?(prepared.qdrant_points, &Map.has_key?(&1.vector, "dense"))
      assert Enum.any?(prepared.qdrant_points, &has_dim?(&1, ctx.user, "zanzibar"))
    end
  end

  test "excalidraw drawing data is not indexed; text elements are, and embedded", ctx do
    note = put_note(ctx, "Sketch.excalidraw.md", @excalidraw)
    chunks = Markdown.parse(note.content, note.path)

    refute Enum.any?(chunks, &(&1.text =~ "qqrect"))
    assert Enum.any?(chunks, &(&1.text =~ "Zanzibar architecture sketch"))
    refute Enum.any?(chunks, &(&1.text =~ "^abc12345"))

    assert {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)

    assert_received {:embedded, sent}
    assert Enum.any?(sent, &(&1 =~ "Zanzibar architecture sketch"))
    refute Enum.any?(sent, &(&1 =~ "qqrect"))
    assert Enum.any?(prepared.qdrant_points, &has_dim?(&1, ctx.user, "zanzibar"))
    refute Enum.any?(prepared.qdrant_points, &has_dim?(&1, ctx.user, "qqrect"))
  end
end
