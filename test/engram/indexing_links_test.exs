defmodule Engram.IndexingLinksTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Indexing
  alias Engram.Links.NoteLink
  alias Engram.Notes

  setup :verify_on_exit!

  # Mirrors test/engram/indexing_test.exs setup.
  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    %{bypass: bypass, user: user, vault: vault}
  end

  defp expect_embed_and_upsert(bypass) do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  test "index_note persists extracted links", %{bypass: bypass, user: user, vault: vault} do
    {:ok, target} =
      Notes.upsert_note(user, vault, %{"path" => "B.md", "content" => "# B", "mtime" => 1_000.0})

    {:ok, source} =
      Notes.upsert_note(user, vault, %{
        "path" => "Source.md",
        "content" => "[[B]]",
        "mtime" => 1_000.0
      })

    expect_embed_and_upsert(bypass)

    assert {:ok, _count} = Indexing.index_note(source, vault)

    links =
      Repo.all(from(l in NoteLink, where: l.source_note_id == ^source.id),
        skip_tenant_check: true
      )

    assert [link] = links
    assert link.target_note_id == target.id
  end

  test "emptying a note clears its links via the no_chunks path", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    {:ok, _target} =
      Notes.upsert_note(user, vault, %{"path" => "B.md", "content" => "# B", "mtime" => 1_000.0})

    {:ok, source} =
      Notes.upsert_note(user, vault, %{
        "path" => "Source.md",
        "content" => "[[B]]",
        "mtime" => 1_000.0
      })

    expect_embed_and_upsert(bypass)

    assert {:ok, _count} = Indexing.index_note(source, vault)

    assert [_link] =
             Repo.all(from(l in NoteLink, where: l.source_note_id == ^source.id),
               skip_tenant_check: true
             )

    {:ok, emptied} =
      Notes.upsert_note(user, vault, %{
        "path" => "Source.md",
        "content" => "",
        "mtime" => 2_000.0
      })

    # no_chunks short-circuit: no embed call, no Qdrant call expected here.
    assert {:ok, 0} = Indexing.index_note(emptied, vault)

    assert [] =
             Repo.all(from(l in NoteLink, where: l.source_note_id == ^source.id),
               skip_tenant_check: true
             )
  end

  test "no_chunks path returns {:error, :no_dek} instead of crashing when the user has no DEK" do
    # Plain factory insert — no ensure_user_dek, unlike the top-level setup's
    # user. upsert_note would auto-provision a DEK, so build the note struct
    # directly (mirrors the old pre-Task-5 "skips embedding" test) to keep
    # the user genuinely DEK-less.
    user = insert(:user)
    vault = insert(:vault, user: user)

    note = %Engram.Notes.Note{
      id: Ecto.UUID.generate(),
      path: "Test/Empty.md",
      content: "",
      user_id: user.id,
      vault_id: vault.id,
      title: "Empty",
      folder: "Test",
      tags: [],
      version: 1,
      content_hash: ""
    }

    assert {:error, :no_dek} = Indexing.index_note(note, vault)

    assert [] =
             Repo.all(from(l in NoteLink, where: l.source_note_id == ^note.id),
               skip_tenant_check: true
             )
  end
end
