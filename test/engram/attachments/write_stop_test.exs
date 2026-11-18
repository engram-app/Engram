defmodule Engram.Attachments.WriteStopTest do
  # S6 step 6 phase 2 (Engram#2523): a folder rename the S5 write stop
  # serves writes ONE folder row and no attachment row either. Readers find
  # and show the attachments by folder row and name (release D), and a
  # plugin older than S4 still learns the move from the moved-folder feed's
  # attachment leg. Inert in prod until the floor PR sets the sentinel.
  use Engram.DataCase, async: true

  import Ecto.Query

  alias Engram.{Attachments, Folders, Notes, Repo, ServiceConfig, Sync}
  alias Engram.Attachments.{Attachment, WriteStop}
  alias Engram.Release.Floor

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    ServiceConfig.put_override(:folder_ops, true)
    ServiceConfig.put_override(:attachment_name_key_ledger, :done)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    for path <- ["A/x.png", "A/sub/y.png"] do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => path,
          "content_base64" => Base.encode64("bytes of " <> path)
        })
    end

    cursor = Repo.with_tenant!(user.id, fn -> Engram.Vaults.raw_current_seq(vault.id) end)
    %{user: user, vault: vault, cursor: cursor}
  end

  defp rows(vault) do
    Repo.all(
      from(a in Attachment,
        where: a.vault_id == ^vault.id,
        order_by: a.id,
        select: {a.id, a.seq, a.path_hmac, a.deleted_at, a.version}
      ),
      skip_tenant_check: true
    )
  end

  defp att_feed(user, vault, cursor, opts) do
    Sync.merged_changes_page(user, vault, cursor, nil, 500, :all, nil, opts).page
    |> Enum.filter(&(&1.type == :attachment))
    |> Enum.map(&{&1.path, &1.deleted})
  end

  test "a folder rename touches 0 attachment rows", %{user: u, vault: v} do
    assert WriteStop.on?()
    before = rows(v)

    assert {:ok, %{notes: 1, attachments: 2}} = Folders.rename(u, v, "A", "B")

    assert rows(v) == before
    assert {:ok, %{content: "bytes of A/x.png"}} = Attachments.get_attachment(u, v, "B/x.png")
    assert {:ok, %{content: _}} = Attachments.get_attachment(u, v, "B/sub/y.png")
    assert {:ok, nil} = Attachments.get_attachment(u, v, "A/x.png")
  end

  test "the old plugin still gets the move; the S4 plugin gets none", %{
    user: u,
    vault: v,
    cursor: cursor
  } do
    {:ok, _} = Folders.rename(u, v, "A", "B")

    old = att_feed(u, v, cursor, [])
    assert {"A/x.png", true} in old
    assert {"B/x.png", false} in old
    assert {"A/sub/y.png", true} in old
    assert {"B/sub/y.png", false} in old
    assert att_feed(u, v, cursor, moved: false) == []
  end

  test "an attachment that is not keyed sends the rename to the cascade", %{user: u, vault: v} do
    Repo.query!(
      "UPDATE attachments SET folder_ref_stamp = NULL WHERE vault_id = $1",
      [Ecto.UUID.dump!(v.id)]
    )

    before = rows(v)
    {:ok, %{attachments: 2}} = Folders.rename(u, v, "A", "B")
    refute rows(v) == before
    assert {:ok, %{content: _}} = Attachments.get_attachment(u, v, "B/x.png")
  end

  test "the kill switch, and an open ledger, send it to the cascade", %{user: u, vault: v} do
    ServiceConfig.put_override(:attachment_write_stop, false)
    refute WriteStop.on?()
    ServiceConfig.put_override(:attachment_write_stop, true)
    ServiceConfig.put_override(:attachment_name_key_ledger, :read)
    refute WriteStop.on?()

    before = rows(v)
    {:ok, _} = Folders.rename(u, v, "A", "B")
    refute rows(v) == before
  end

  test "a peer on a build without the attachment readers keeps it off" do
    peer = :"engram@10.0.0.9"
    fleet = &[role: nil, query: nil, peers: fn -> [peer] end, multicall: fn _ -> [&1] end]

    # An older build has no `Location.s6_reads/0`.
    refute WriteStop.on?(fleet.({:error, {:exception, :undef, []}}))
    refute WriteStop.on?(fleet.({:ok, 0}))
    assert WriteStop.on?(fleet.({:ok, 1}))
  end

  test "with the note write stop off it is off, and the rename cascades", %{user: u, vault: v} do
    ServiceConfig.put_override(:folder_ops, false)
    refute WriteStop.on?()

    before = rows(v)
    {:ok, _} = Folders.rename(u, v, "A", "B")
    refute rows(v) == before
  end

  test "an attachment that does not decrypt sends the rename to the cascade",
       %{user: u, vault: v} do
    {:ok, bad} =
      Attachments.upsert_attachment(u, v, %{
        "path" => "A/bad.png",
        "content_base64" => Base.encode64("bad")
      })

    Repo.query!("UPDATE attachments SET path_ciphertext = 'garbage' WHERE id = $1", [
      Ecto.UUID.dump!(bad.id)
    ])

    before = rows(v)
    {:ok, _} = Folders.rename(u, v, "A", "B")
    refute rows(v) == before
    assert {:ok, %{content: "bytes of A/x.png"}} = Attachments.get_attachment(u, v, "B/x.png")
  end

  # The floor PR (Todd's approval, via god) flips this with the sentinel.
  test "inert until the rollback floor reaches the attachment readers release" do
    refute Floor.at_least?(WriteStop.reads_release())
    refute WriteStop.floors?(:enforce)
  end
end
