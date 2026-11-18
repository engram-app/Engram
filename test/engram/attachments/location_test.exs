defmodule Engram.Attachments.LocationTest do
  # S6 step 6 read switch (Engram#2523): an attachment under a folder moved
  # without a cascade keeps its OLD stored path (the next release stops the
  # attachment cascade; this one is its rollback target and N-1). Every
  # reader must serve it where its folder row puts it, every writer must find
  # it there, and a client older than the S4 plugin must be told to move it.
  # The move is made here the way that release will make it: the notes leg's
  # uncascaded move, no attachment leg.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Attachments, Notes, Repo, ServiceConfig, Sync}
  alias Engram.Attachments.{Attachment, Location}
  alias Engram.DataMigrations.AttachmentNameKey

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    att = put_att(user, vault, "A/x.png", "old bytes")
    cursor = Repo.with_tenant!(user.id, fn -> Engram.Vaults.raw_current_seq(vault.id) end)
    move!(user, vault, "A", "B")
    %{user: user, vault: vault, att: att, cursor: cursor}
  end

  defp put_att(user, vault, path, bytes) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64(bytes)
      })

    att
  end

  # The folder row moves at one seq; no attachment row is written.
  defp move!(user, vault, old, new) do
    {:ok, {:ok, 1}} =
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, old, new) end)
  end

  defp live(vault) do
    Repo.all(
      from(a in Attachment, where: a.vault_id == ^vault.id and is_nil(a.deleted_at)),
      skip_tenant_check: true
    )
  end

  defp feed(user, vault, cursor, opts \\ []) do
    Sync.merged_changes_page(user, vault, cursor, nil, 500, :all, nil, opts).page
    |> Enum.filter(&(&1.type == :attachment))
    |> Enum.map(&{&1.path, &1.deleted})
  end

  test "the stored path is still the old one (the state under test)", %{att: att, vault: v} do
    assert [%{id: id, path_hmac: h}] = live(v)
    assert id == att.id
    assert h == att.path_hmac
  end

  test "a by-path read finds it at its shown path only", %{user: u, vault: v, att: att} do
    assert {:ok, %{id: id, path: "B/x.png", content: "old bytes"}} =
             Attachments.get_attachment(u, v, "B/x.png")

    assert id == att.id
    assert {:ok, nil} = Attachments.get_attachment(u, v, "A/x.png")
  end

  test "listings and the feed serve the shown path", %{user: u, vault: v} do
    assert {:ok, [%{path: "B/x.png"}]} = Attachments.list_attachments(u, v)
    assert {:ok, [%{path: "B/x.png"}]} = Attachments.list_in_folder(u, v, "B")
    assert {:ok, []} = Attachments.list_in_folder(u, v, "A")

    {:ok, %{changes: changes}} = Attachments.list_changes_by_seq(u, v, 0)
    assert [%{path: "B/x.png", deleted: false}] = changes

    {paths, seqs} = Location.listing(u, v.id)
    assert Map.values(paths) == ["B/x.png"]
    assert [seq] = Map.values(seqs)
    assert seq > 0
  end

  test "a write at the shown path updates the same row and trashes the old path",
       %{user: u, vault: v, att: att, cursor: cursor} do
    _ = put_att(u, v, "B/x.png", "new bytes")

    assert [%{id: id}] = live(v)
    assert id == att.id
    assert {:ok, %{content: "new bytes"}} = Attachments.get_attachment(u, v, "B/x.png")
    assert {"A/x.png", true} in feed(u, v, cursor, moved: false)
  end

  test "a new file at the old path takes it, the moved one stays shown",
       %{user: u, vault: v, att: att} do
    fresh = put_att(u, v, "A/x.png", "another file")

    assert fresh.id != att.id
    assert {:ok, %{id: id, content: "old bytes"}} = Attachments.get_attachment(u, v, "B/x.png")
    assert id == att.id
    assert {:ok, %{content: "another file"}} = Attachments.get_attachment(u, v, "A/x.png")
  end

  test "a delete at the shown path deletes it and tells both clients",
       %{user: u, vault: v, cursor: cursor} do
    assert :deleted = Attachments.delete_attachment_reporting(u, v, "B/x.png")
    assert live(v) == []

    rows = feed(u, v, cursor, moved: false)
    assert {"A/x.png", true} in rows
    assert {"B/x.png", true} in rows
  end

  test "a client older than S4 is told to move it; the S4 plugin is not",
       %{user: u, vault: v, cursor: cursor} do
    assert feed(u, v, cursor) == [{"A/x.png", true}, {"B/x.png", false}]
    assert feed(u, v, cursor, moved: false) == []

    head = Repo.with_tenant!(u.id, fn -> Sync.feed_head(u, v) end)
    assert head > cursor
  end

  # 1.39.3's catch-up walk: the cursor is the max `(seq, id)` it has seen.
  test "the pair is never split across pages", %{user: u, vault: v, cursor: cursor} do
    pages =
      Stream.unfold({cursor, nil}, fn
        :done ->
          nil

        {seq, id} ->
          page = Sync.merged_changes_page(u, v, seq, id, 1, :all, nil, [])
          next = Enum.reduce(page.page, {seq, id}, &max_cursor/2)
          {page.page, if(page.has_more and next != {seq, id}, do: next, else: :done)}
      end)
      |> Enum.to_list()

    refute Enum.any?(pages, &match?(%{pair: _}, List.last(&1) || %{}))

    rows = pages |> List.flatten() |> Enum.filter(&(&1.type == :attachment))
    assert Enum.map(rows, &{&1.path, &1.deleted}) == [{"A/x.png", true}, {"B/x.png", false}]
  end

  defp max_cursor(%{seq: s, id: i}, {cs, ci}) do
    if s > cs or (s == cs and i > (ci || "")), do: {s, i}, else: {cs, ci}
  end

  describe "the attachment_name_key ledger" do
    test "keys a row the trigger never saw, and off it runs no pass", %{vault: v, att: att} do
      raw = Ecto.UUID.dump!(att.id)
      Repo.query!("ALTER TABLE attachments DISABLE TRIGGER attachments_set_name_key")

      try do
        Repo.query!("UPDATE attachments SET name_key = NULL WHERE id = $1", [raw])
      after
        Repo.query!("ALTER TABLE attachments ENABLE TRIGGER attachments_set_name_key")
      end

      key = fn ->
        Repo.query!("SELECT name_key FROM attachments WHERE id = $1", [raw]).rows
      end

      assert [[nil]] = key.()

      ServiceConfig.put_override(:attachment_name_key, false)
      refute AttachmentNameKey.enabled?()
      ServiceConfig.put_override(:attachment_name_key, true)

      AttachmentNameKey.run_pass()
      assert [[k]] = key.()
      assert is_binary(k)
      assert [_] = live(v)
    end

    test "a stale folder reference clears the key", %{att: att} do
      raw = Ecto.UUID.dump!(att.id)
      Repo.query!("UPDATE attachments SET folder_ref_stamp = NULL WHERE id = $1", [raw])

      assert [[nil]] =
               Repo.query!("SELECT name_key FROM attachments WHERE id = $1", [raw]).rows
    end
  end
end
