defmodule Engram.IndexingChunkReuseTest do
  @moduledoc """
  #1592 — a re-index must only embed the chunks whose text actually changed.

  Reuse is keyed on `context_text` ("folder > title > heading\\n\\ntext"),
  which is the exact string handed to the embedder. Keying on the bare chunk
  text would preserve vectors built under a stale title or folder.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk

  setup :verify_on_exit!

  @path "Health/Iron Panel.md"

  defp content(ferritin_body, tags) do
    """
    ---
    tags: #{tags}
    ---
    # Iron Panel

    Intro paragraph.

    ## Ferritin

    #{ferritin_body}

    ## Transferrin

    Transferrin saturation is normal.
    """
  end

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    :ok = Engram.Fixtures.grant_semantic!(user)
    vault = insert(:vault, user: user)

    {:ok, recorder} = Agent.start_link(fn -> [] end)

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      Agent.update(recorder, fn acc ->
        [%{method: conn.method, path: conn.request_path, body: decode(body)} | acc]
      end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    %{bypass: bypass, user: user, vault: vault, recorder: recorder}
  end

  defp decode(""), do: %{}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp requests(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()

  defp reset(recorder), do: Agent.update(recorder, fn _ -> [] end)

  defp upserts(recorder) do
    recorder
    |> requests()
    |> Enum.filter(&(&1.method == "PUT" and String.ends_with?(&1.path, "/points")))
    |> Enum.flat_map(&Map.get(&1.body, "points", []))
  end

  defp set_payloads(recorder) do
    recorder
    |> requests()
    |> Enum.filter(&String.ends_with?(&1.path, "/points/payload"))
  end

  defp deletes(recorder) do
    recorder
    |> requests()
    |> Enum.filter(&String.ends_with?(&1.path, "/points/delete"))
  end

  defp deleted_ids(recorder) do
    recorder |> deletes() |> Enum.flat_map(&Map.get(&1.body, "points", []))
  end

  defp chunk_rows(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position),
      skip_tenant_check: true
    )
  end

  defp put_note(user, vault, body, tags \\ "[health]") do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => @path,
        "content" => content(body, tags),
        "mtime" => 1_000.0
      })

    note
  end

  # Embeds every text handed over, recording them so a test can assert on
  # exactly which chunks were sent to the embedder.
  defp stub_embedder(test_pid) do
    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test_pid, {:embedded, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp embedded_texts do
    receive do
      {:embedded, texts} -> texts ++ embedded_texts()
    after
      0 -> []
    end
  end

  describe "re-index with no content change" do
    test "embeds nothing and keeps every point id", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      stub_embedder(self())

      assert {:ok, count} = Indexing.index_note(note, ctx.vault)
      assert count > 2, "fixture must produce several chunks (got #{count})"
      first_ids = note |> chunk_rows() |> Enum.map(& &1.qdrant_point_id)
      _ = embedded_texts()
      reset(ctx.recorder)

      assert {:ok, ^count} = Indexing.index_note(note, ctx.vault)

      assert embedded_texts() == [], "an unchanged note must not reach the embedder"
      assert upserts(ctx.recorder) == [], "an unchanged note must not re-upsert vectors"
      assert deleted_ids(ctx.recorder) == []
      assert note |> chunk_rows() |> Enum.map(& &1.qdrant_point_id) == first_ids
    end
  end

  describe "re-index after editing one section" do
    test "embeds only the chunks whose context_text changed", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      stub_embedder(self())

      assert {:ok, count} = Indexing.index_note(note, ctx.vault)
      _ = embedded_texts()
      reset(ctx.recorder)

      edited = put_note(ctx.user, ctx.vault, "Ferritin levels recovered to 90 ng/mL.")
      assert {:ok, ^count} = Indexing.index_note(edited, ctx.vault)

      sent = embedded_texts()
      assert sent != [], "the edited section must be re-embedded"
      assert length(sent) < count, "unchanged sections must not be re-embedded"
      assert Enum.all?(sent, &(&1 =~ "Ferritin levels recovered"))
      assert length(upserts(ctx.recorder)) == length(sent)
    end

    test "reused points keep their ids and the replaced point is deleted", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      stub_embedder(self())

      assert {:ok, _} = Indexing.index_note(note, ctx.vault)
      before = note |> chunk_rows() |> Map.new(&{&1.position, &1.qdrant_point_id})
      _ = embedded_texts()
      reset(ctx.recorder)

      edited = put_note(ctx.user, ctx.vault, "Ferritin levels recovered to 90 ng/mL.")
      assert {:ok, _} = Indexing.index_note(edited, ctx.vault)
      now = edited |> chunk_rows() |> Map.new(&{&1.position, &1.qdrant_point_id})

      replaced = for {pos, id} <- before, Map.get(now, pos) != id, do: id
      assert length(replaced) == 1, "exactly one section changed"

      kept = for {pos, id} <- now, Map.get(before, pos) == id, do: id
      assert length(kept) == map_size(now) - 1, "every unchanged chunk must keep its point"
      assert deleted_ids(ctx.recorder) == replaced, "the replaced point must be deleted"
    end
  end

  describe "note-level payload on reused points" do
    test "a frontmatter tag edit refreshes tags_hmac on every reused point", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.", "[health]")
      stub_embedder(self())

      assert {:ok, _} = Indexing.index_note(note, ctx.vault)
      _ = embedded_texts()
      reset(ctx.recorder)

      retagged = put_note(ctx.user, ctx.vault, "Ferritin levels are low.", "[health, labs]")
      assert {:ok, _} = Indexing.index_note(retagged, ctx.vault)

      expected = Enum.map(retagged.tags_hmac || [], &Base.encode64/1)
      assert length(expected) == 2, "fixture must carry both tags"

      reused_ids =
        retagged
        |> chunk_rows()
        |> Enum.map(& &1.qdrant_point_id)
        |> Enum.reject(&(&1 in Enum.flat_map(upserts(ctx.recorder), fn p -> [p["id"]] end)))

      assert reused_ids != [], "the body chunks must be reused"

      patch = set_payloads(ctx.recorder)
      assert [%{body: %{"points" => points, "payload" => payload}}] = patch

      assert Enum.sort(points) == Enum.sort(reused_ids)

      assert Enum.sort(payload["tags_hmac"]) == Enum.sort(expected),
             "reused points would otherwise answer tag filters with the pre-edit tags"
    end
  end

  describe "after the rename pre-delete" do
    test "nothing is reused, because those points are already gone", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      stub_embedder(self())

      assert {:ok, count} = Indexing.index_note(note, ctx.vault)
      _ = embedded_texts()

      # What `EmbedNote` does on a rename: wipe the points filed under the OLD
      # path_hmac, then re-index. A same-folder rename of a note with a heading
      # leaves every context_text identical, so without invalidation the
      # re-index would reuse ids that no longer exist in Qdrant.
      old_hmac = Base.encode64(note.path_hmac)
      assert :ok = Indexing.delete_points_by_path_hmac(note, old_hmac)

      reset(ctx.recorder)
      assert {:ok, ^count} = Indexing.index_note(note, ctx.vault)

      assert length(embedded_texts()) == count, "every chunk must be rebuilt"
      assert length(upserts(ctx.recorder)) == count
      assert set_payloads(ctx.recorder) == []
    end
  end

  describe "rows with no hmac" do
    test "a nil context_hmac forces a full re-embed", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      stub_embedder(self())

      assert {:ok, count} = Indexing.index_note(note, ctx.vault)
      _ = embedded_texts()

      # The shape of every row written before this column existed.
      Repo.update_all(
        from(c in Chunk, where: c.note_id == ^note.id),
        [set: [context_hmac: nil]],
        skip_tenant_check: true
      )

      reset(ctx.recorder)
      assert {:ok, ^count} = Indexing.index_note(note, ctx.vault)

      assert length(embedded_texts()) == count
    end
  end

  describe "duplicate chunks" do
    test "two identical sections get two distinct points", ctx do
      body = "# Iron Panel\n\n## A\n\nsame text here\n\n## B\n\nsame text here\n"

      {:ok, note} =
        Notes.upsert_note(ctx.user, ctx.vault, %{
          "path" => "Health/Dupes.md",
          "content" => body,
          "mtime" => 1_000.0
        })

      stub_embedder(self())

      assert {:ok, count} = Indexing.index_note(note, ctx.vault)
      ids = note |> chunk_rows() |> Enum.map(& &1.qdrant_point_id)
      assert length(Enum.uniq(ids)) == count, "identical chunks must not share a point"

      _ = embedded_texts()
      reset(ctx.recorder)

      assert {:ok, ^count} = Indexing.index_note(note, ctx.vault)
      assert embedded_texts() == []

      assert note |> chunk_rows() |> Enum.map(& &1.qdrant_point_id) |> Enum.sort() ==
               Enum.sort(ids)
    end
  end
end
