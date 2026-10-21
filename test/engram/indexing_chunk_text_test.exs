defmodule Engram.IndexingChunkTextTest do
  @moduledoc """
  Task 11.2, hybrid: the indexing pass writes a `chunk_points` row per point,
  in the same transaction as its `chunks` row, with the display-text
  checksum (`slice_sum`), and for a note over the display threshold its text
  and heading as ONE envelope (`display_ct`).
  Search shows a small note's chunk re-derived from the note content. Behind
  `:chunk_text_write` (off), and always on for the v5 layout, whose payload
  carries no text.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.{Indexing, Notes, ServiceConfig}
  alias Engram.Notes.{Chunk, ChunkPoint}

  setup :verify_on_exit!

  @path "Health/Iron Panel.md"

  # Each section is padded past the v5 chunker's 512-byte coalesce floor,
  # so the three sections stay three chunks.
  @pad String.duplicate("Reference ranges and units vary by lab. ", 15)

  defp content(ferritin_body) do
    """
    # Iron Panel

    Intro paragraph. #{@pad}

    ## Ferritin

    #{ferritin_body} #{@pad}

    ## Transferrin

    Transferrin saturation is normal. #{@pad}
    """
  end

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

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, body, content \\ nil) do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => @path, "content" => content || content(body), "mtime" => 1_000.0},
        actor: "api"
      )

    note
  end

  defp points(note) do
    Repo.all(from(p in ChunkPoint, where: p.note_id == ^note.id, order_by: p.position),
      skip_tenant_check: true
    )
  end

  defp rows(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position),
      skip_tenant_check: true
    )
  end

  # What search shows for each row, by position, through the read path.
  defp texts(note, user) do
    user = Repo.reload!(user, skip_tenant_check: true)
    rows = rows(note)
    ids = Enum.map(rows, &to_string(&1.qdrant_point_id))
    {:ok, hits} = Notes.search_hits_by_qdrant_points(user, ids)
    for id <- ids, do: {hits[id].text, hits[id].heading_path}
  end

  test "flag off: rows carry no text (prod writes unchanged)", ctx do
    note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
    assert {:ok, count} = Indexing.index_note(note, ctx.vault)
    assert count > 2
    assert points(note) == []
  end

  describe "flag on" do
    setup do
      ServiceConfig.put_override(:chunk_text_write, true)
      :ok
    end

    test "a small note stores checksums only and displays from its content", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      assert {:ok, count} = Indexing.index_note(note, ctx.vault)

      points = points(note)
      assert length(points) == count
      assert Enum.all?(points, &(is_integer(&1.slice_sum) and is_nil(&1.display_ct)))

      # One point row per chunk row, same point ids and offsets.
      assert Enum.map(points, &{&1.point_id, &1.position, &1.char_start, &1.char_end}) ==
               Enum.map(
                 rows(note),
                 &{&1.qdrant_point_id, &1.position, &1.char_start, &1.char_end}
               )

      pairs = texts(note, ctx.user)
      assert length(pairs) == count
      assert {text, heading} = Enum.find(pairs, fn {t, _} -> t =~ "Ferritin levels are low." end)
      assert heading =~ "Ferritin"
      refute text =~ "Transferrin saturation"
    end

    test "a note over the threshold (300 KB) stores display_ct and displays from it", ctx do
      filler = String.duplicate("Iron stores and lab values. ", 11_000)
      big = content("Ferritin levels are low.") <> "\n## Appendix\n\n" <> filler
      assert byte_size(big) > 300_000
      note = put_note(ctx.user, ctx.vault, nil, big)
      assert {:ok, _count} = Indexing.index_note(note, ctx.vault)

      assert Enum.all?(points(note), &(is_binary(&1.display_ct) and is_integer(&1.slice_sum)))

      # Search reads the envelope, not the content: corrupting the content
      # ciphertext leaves every hit's text intact.
      {:ok, _} =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.update_all(from(n in Engram.Notes.Note, where: n.id == ^note.id),
            set: [content_ciphertext: :crypto.strong_rand_bytes(64)]
          )
        end)

      pairs = texts(note, ctx.user)
      assert {_text, heading} = Enum.find(pairs, fn {t, _} -> t =~ "Ferritin levels are low." end)
      assert heading =~ "Ferritin"
    end

    test "a sparse-only (budget-parked) pass also writes text", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")

      assert {:ok, count, 0, false} =
               Indexing.index_note_with_usage(note, ctx.vault, nil, dense: false)

      pairs = texts(note, ctx.user)
      assert length(pairs) == count
      assert Enum.any?(pairs, fn {t, _} -> t =~ "Ferritin levels are low." end)
    end

    test "a floor point writes its row's text too (empty: no display text)", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")

      assert {:ok, _, _, _} =
               Indexing.index_note_with_usage(note, ctx.vault, nil, index_tier: "floor")

      assert [{"", nil}] = texts(note, ctx.user)
    end

    test "editing one section rewrites its text and keeps the others", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      assert {:ok, _} = Indexing.index_note(note, ctx.vault)
      before = Map.new(rows(note), &{&1.qdrant_point_id, &1.position})

      edited = put_note(ctx.user, ctx.vault, "Ferritin recovered to 90 ng/mL.")
      assert {:ok, _} = Indexing.index_note(edited, ctx.vault)

      pairs = texts(edited, ctx.user)
      assert Enum.any?(pairs, fn {t, _} -> t =~ "recovered to 90" end)
      refute Enum.any?(pairs, fn {t, _} -> t =~ "levels are low" end)
      assert Enum.any?(pairs, fn {t, _} -> t =~ "Transferrin saturation is normal." end)

      # The unchanged sections kept their points (reuse), and their text still
      # decrypts under the same point id.
      kept = Enum.count(rows(edited), &Map.has_key?(before, &1.qdrant_point_id))
      assert kept >= 2
    end
  end

  test "the v5 layout writes text even with the flag off", ctx do
    prev = Application.get_env(:engram, :write_v5_layout)
    Application.put_env(:engram, :write_v5_layout, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :write_v5_layout),
        else: Application.put_env(:engram, :write_v5_layout, prev)
    end)

    note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
    assert {:ok, _} = Indexing.index_note(note, ctx.vault)

    assert Enum.any?(texts(note, ctx.user), fn {t, _} -> t =~ "Ferritin levels are low." end)
  end
end
