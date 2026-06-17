defmodule Engram.AttachmentsSeqFeedTest do
  use Engram.DataCase, async: true

  alias Engram.{Attachments, Repo, Vaults}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp b64(bin), do: Base.encode64(bin)

  defp att_row(user, id) do
    {:ok, row} = Repo.with_tenant(user.id, fn -> Repo.get(Attachments.Attachment, id) end)
    row
  end

  defp put(user, vault, path) do
    Attachments.upsert_attachment(user, vault, %{
      "path" => path,
      "content_base64" => b64(path),
      "mime_type" => "image/png"
    })
  end

  test "version starts at 1 and bumps on update", %{user: user, vault: vault} do
    {:ok, a} = put(user, vault, "a.png")
    assert att_row(user, a.id).version == 1

    {:ok, _} = put(user, vault, "a.png")
    assert att_row(user, a.id).version == 2
  end

  test "attachment seq feed returns seq>cursor incl tombstones", %{user: user, vault: vault} do
    {:ok, _a} = put(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    {:ok, %{changes: ch}} = Attachments.list_changes_by_seq(user, vault, 0)
    assert Enum.any?(ch, &(&1.path == "a.png" and &1.deleted))
    assert Enum.all?(ch, &is_integer(&1.seq))
  end

  test "attachment seq feed: keyset ordering, version, and pagination", %{
    user: user,
    vault: vault
  } do
    {:ok, _} = put(user, vault, "x.png")
    {:ok, _} = put(user, vault, "y.png")
    {:ok, _} = put(user, vault, "z.png")

    {:ok, %{changes: ch, has_more: more, next: next}} =
      Attachments.list_changes_by_seq(user, vault, 0, limit: 2)

    assert length(ch) == 2
    assert more
    assert {seq, id} = next
    assert is_integer(seq) and is_binary(id)

    # seq strictly ascending across the page
    seqs = Enum.map(ch, & &1.seq)
    assert seqs == Enum.sort(seqs)

    # every entry carries the full metadata contract
    for c <- ch do
      assert is_integer(c.seq)
      assert is_integer(c.version)
      assert is_boolean(c.deleted)
      assert is_binary(c.id)
      assert is_binary(c.path)
      assert is_binary(c.mime_type)
      assert Map.has_key?(c, :size_bytes)
      assert Map.has_key?(c, :mtime)
      assert Map.has_key?(c, :updated_at)
      refute Map.has_key?(c, :deleted_at)
    end

    # resume from the cursor returns the remainder, exhausting the feed
    {:ok, %{changes: ch2, has_more: more2, next: next2}} =
      Attachments.list_changes_by_seq(user, vault, seq, limit: 2, after_id: id)

    assert length(ch2) == 1
    refute more2
    assert is_nil(next2)
  end
end
