defmodule Engram.IndexingChunkTextTest do
  @moduledoc """
  Task 11.2: the indexing pass writes each chunk's display text and heading,
  encrypted, onto its `chunks` row, in the same INSERT as the row. Behind
  `:chunk_text_write` (off), and always on for the v5 layout, whose payload
  carries no text.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.{Crypto, Indexing, Notes, ServiceConfig}
  alias Engram.Notes.Chunk

  setup :verify_on_exit!

  @path "Health/Iron Panel.md"

  # Over 512 B a section: the v5 chunker's min512 coalesce (#2084) would
  # otherwise merge these short sections into one chunk.
  @pad String.duplicate("filler words here ", 30)

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

  defp put_note(user, vault, body) do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => @path, "content" => content(body), "mtime" => 1_000.0},
        actor: "api"
      )

    note
  end

  defp rows(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position),
      skip_tenant_check: true
    )
  end

  defp texts(note, user) do
    {:ok, dek} = Crypto.get_dek(Repo.reload!(user, skip_tenant_check: true))

    for row <- rows(note) do
      {:ok, pair} = Crypto.decrypt_chunk_text(row, dek, row.qdrant_point_id)
      pair
    end
  end

  test "flag off: rows carry no text (prod writes unchanged)", ctx do
    note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
    assert {:ok, count} = Indexing.index_note(note, ctx.vault)
    assert count > 2
    assert Enum.all?(rows(note), &is_nil(&1.text_ciphertext))
  end

  describe "flag on" do
    setup do
      ServiceConfig.put_override(:chunk_text_write, true)
      :ok
    end

    test "every row decrypts to its chunk's text and heading", ctx do
      note = put_note(ctx.user, ctx.vault, "Ferritin levels are low.")
      assert {:ok, count} = Indexing.index_note(note, ctx.vault)

      pairs = texts(note, ctx.user)
      assert length(pairs) == count
      assert {text, heading} = Enum.find(pairs, fn {t, _} -> t =~ "Ferritin levels are low." end)
      assert heading =~ "Ferritin"
      refute text =~ "Transferrin saturation"
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
