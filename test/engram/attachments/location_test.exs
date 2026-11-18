defmodule Engram.Attachments.LocationTest do
  # S6 step 6 read switch (Engram#2523): an attachment under a folder moved
  # without a cascade keeps its OLD stored path (the next release stops the
  # attachment cascade; this one is its rollback target and N-1). Every
  # reader must serve it where its folder row puts it, every writer must find
  # it there without telling any client to trash the stale stored path (it
  # may hold an unrelated file by now), and a client older than the S4
  # plugin must be told to move it.
  # The move is made here the way that release will make it: the notes leg's
  # uncascaded move, no attachment leg.
  use Engram.DataCase, async: false

  import Ecto.Query

  # Main's public API only, so the file compiles on main and every test
  # here is a behavioural red there (the ledger and `Location` have their
  # own files).
  alias Engram.{Attachments, Notes, Repo, Sync}
  alias Engram.Attachments.Attachment

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

  # Every broadcast this process received, as text.
  defp broadcasts do
    receive do
      msg -> [inspect(msg) | broadcasts()]
    after
      0 -> []
    end
  end

  defp subscribe(user, vault),
    do: Phoenix.PubSub.subscribe(Engram.PubSub, "sync:#{user.id}:#{vault.id}")

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
  end

  # Review B1: the stale stored path is never tombstoned nor broadcast.
  test "a write at the shown path updates the same row and says nothing of the stored path",
       %{user: u, vault: v, att: att, cursor: cursor} do
    subscribe(u, v)
    _ = put_att(u, v, "B/x.png", "new bytes")

    assert [%{id: id}] = live(v)
    assert id == att.id
    assert {:ok, %{content: "new bytes"}} = Attachments.get_attachment(u, v, "B/x.png")
    refute Enum.any?(feed(u, v, cursor, moved: false), &match?({"A/x.png", _}, &1))
    msgs = broadcasts()
    assert Enum.any?(msgs, &(&1 =~ "B/x.png")), "no broadcast seen at all: #{inspect(msgs)}"
    refute Enum.any?(msgs, &(&1 =~ "A/x.png"))
  end

  test "a new file at the old path takes it, the moved one stays shown",
       %{user: u, vault: v, att: att} do
    subscribe(u, v)
    fresh = put_att(u, v, "A/x.png", "another file")

    assert fresh.id != att.id
    assert {:ok, %{id: id, content: "old bytes"}} = Attachments.get_attachment(u, v, "B/x.png")
    assert id == att.id
    assert {:ok, %{content: "another file"}} = Attachments.get_attachment(u, v, "A/x.png")
    msgs = broadcasts()
    assert Enum.any?(msgs, &(&1 =~ "A/x.png")), "no broadcast seen at all: #{inspect(msgs)}"
    refute Enum.any?(msgs, &(&1 =~ ~s("delete")))
  end

  test "a delete at the shown path tombstones the shown path only",
       %{user: u, vault: v, cursor: cursor} do
    assert :deleted = Attachments.delete_attachment_reporting(u, v, "B/x.png")
    assert live(v) == []

    rows = feed(u, v, cursor, moved: false)
    assert {"B/x.png", true} in rows
    refute {"A/x.png", true} in rows
  end

  # Review B2: a stale row that cannot be repointed (its shown slot is held
  # by another file shown there) fails the write; nothing is overwritten.
  test "a heal that cannot land fails the write closed", %{user: u, vault: v, att: att} do
    other = put_att(u, v, "C/z.png", "other file")
    {:ok, fk} = Engram.Crypto.dek_filter_key(u)

    # `other` holds B/x.png's slot by its stored key and is not keyed, so it
    # is shown at its stored path: a different file than the moved one.
    Repo.query!(
      "UPDATE attachments SET path_hmac = $2, folder_ref_stamp = NULL WHERE id = $1",
      [Ecto.UUID.dump!(other.id), Engram.Crypto.hmac_field(fk, "B/x.png")]
    )

    before = live(v) |> Enum.map(&{&1.id, &1.path_hmac, &1.storage_key}) |> Enum.sort()

    assert {:error, :conflict} =
             Attachments.upsert_attachment(u, v, %{
               "path" => "B/x.png",
               "content_base64" => Base.encode64("would overwrite")
             })

    assert {:error, :conflict} = Attachments.delete_attachment(u, v, "B/x.png")
    assert before == live(v) |> Enum.map(&{&1.id, &1.path_hmac, &1.storage_key}) |> Enum.sort()
    assert Enum.any?(live(v), &(&1.id == att.id))
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
end
