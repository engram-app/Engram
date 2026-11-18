defmodule Engram.Attachments.LocationWritersTest do
  # S6 step 6 (Engram#2523), the writers `location_test.exs` does not reach:
  # folder delete, chunked upload, single and batch move, restore, and rows
  # written the way 0.89.0 writes them. Each runs under a folder moved
  # without a cascade, so the attachment's stored path (A/...) is stale and
  # its shown path (B/...) is the truth.
  # Main's public API only, so every test here is a behavioural red there.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Attachments, Crypto, Folders, Notes, Repo, Sync}
  alias Engram.Attachments.{Attachment, Uploads}

  defp world do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    note!(user, vault, "A/n.md")
    %{user: user, vault: vault}
  end

  defp moved_world do
    %{user: u, vault: v} = w = world()
    att = put_att(u, v, "A/x.png", "old bytes")
    cursor = Repo.with_tenant!(u.id, fn -> Engram.Vaults.raw_current_seq(v.id) end)
    move!(u, v, "A", "B")
    Map.merge(w, %{att: att, cursor: cursor})
  end

  defp note!(user, vault, path) do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "n"}, actor: "api")
  end

  defp put_att(user, vault, path, bytes) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64(bytes)
      })

    att
  end

  defp move!(user, vault, old, new) do
    # The folder row moves; the count is its notes and markers.
    {:ok, {:ok, n}} =
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, old, new) end)

    true = n > 0
  end

  defp live(vault) do
    Repo.all(
      from(a in Attachment, where: a.vault_id == ^vault.id and is_nil(a.deleted_at)),
      skip_tenant_check: true
    )
  end

  # A move's tombstone and repoint share one seq, so their order is by id.
  defp feed(user, vault, cursor) do
    Sync.merged_changes_page(user, vault, cursor, nil, 500, :all, nil, moved: false).page
    |> Enum.filter(&(&1.type == :attachment))
    |> Enum.map(&{&1.path, &1.deleted})
  end

  defp at(user, vault, path) do
    {:ok, att} = Attachments.get_attachment(user, vault, path)
    att && %{id: att.id, content: bytes(att.content)}
  end

  # Format v2 serves the file as a lazy segment stream.
  defp bytes({:segments, stream}),
    do: stream |> Enum.map(fn {:ok, b} -> b end) |> IO.iodata_to_binary()

  defp bytes(content), do: content

  defp refute_stale_path(user, vault, cursor) do
    refute Enum.any?(feed(user, vault, cursor), &match?({"A/" <> _, _}, &1))
  end

  describe "folder delete" do
    test "batch_delete at the shown path takes the moved row" do
      %{user: u, vault: v, cursor: c} = moved_world()

      assert {:ok, %{deleted: 1}} = Attachments.batch_delete(u, v, ["B/x.png"])
      assert live(v) == []
      assert {"B/x.png", true} in feed(u, v, c)
      refute_stale_path(u, v, c)
    end

    test "a recursive delete of the moved folder takes its attachment" do
      %{user: u, vault: v, cursor: c} = moved_world()

      assert {:ok, _} = Folders.delete(u, v, "B", recursive: true)
      assert live(v) == []
      assert {"B/x.png", true} in feed(u, v, c)
      refute_stale_path(u, v, c)
    end
  end

  describe "chunked upload" do
    test "start and complete at the shown path overwrite the moved row" do
      %{user: u, vault: v, att: att, cursor: c} = moved_world()
      bytes = "new upload bytes"

      {:ok, up} =
        Uploads.start(u, v, %{path: "B/x.png", size_bytes: byte_size(bytes), mtime: 1.0})

      assert up.attachment_id == att.id
      assert {:ok, %{part: 1}} = Uploads.put_part(u, v, up.id, 1, bytes)
      assert {:ok, %{id: id, path: "B/x.png"}} = Uploads.complete(u, v, up.id)

      assert id == att.id
      assert [%{id: ^id}] = live(v)
      assert at(u, v, "B/x.png") == %{id: id, content: bytes}
      refute_stale_path(u, v, c)
    end
  end

  describe "move" do
    test "a single move from the shown path" do
      %{user: u, vault: v, att: att, cursor: c} = moved_world()

      assert {:ok, %{id: id, path: "B/y.png"}} =
               Attachments.move_attachment(u, v, "B/x.png", "B/y.png")

      assert id == att.id
      assert at(u, v, "B/y.png") == %{id: id, content: "old bytes"}
      assert at(u, v, "B/x.png") == nil
      assert Enum.sort(feed(u, v, c)) == [{"B/x.png", true}, {"B/y.png", false}]
    end

    test "a batch move from the shown path" do
      %{user: u, vault: v, att: att, cursor: c} = moved_world()

      assert {:ok, %{moved: 1}} = Attachments.batch_move(u, v, ["B/x.png"], "C")
      assert at(u, v, "C/x.png") == %{id: att.id, content: "old bytes"}
      assert at(u, v, "B/x.png") == nil
      assert Enum.sort(feed(u, v, c)) == [{"B/x.png", true}, {"C/x.png", false}]
    end
  end

  # D's own folder ops still cascade attachments: each must move the row it
  # finds at the shown path, not skip it as missing at its stored key.
  describe "folder rename and folder batch move of the moved folder" do
    test "Folders.rename carries the moved row to the new name" do
      %{user: u, vault: v, att: att, cursor: c} = moved_world()

      assert {:ok, %{attachments: 1}} = Folders.rename(u, v, "B", "C")
      assert at(u, v, "C/x.png") == %{id: att.id, content: "old bytes"}
      assert at(u, v, "B/x.png") == nil
      refute_stale_path(u, v, c)
    end

    test "Folders.batch_move carries the moved row under the target" do
      %{user: u, vault: v} = world()
      {:ok, marker} = Notes.create_folder_marker(u, v, "A")
      {:ok, _} = Notes.create_folder_marker(u, v, "Z")
      att = put_att(u, v, "A/x.png", "old bytes")
      c = Repo.with_tenant!(u.id, fn -> Engram.Vaults.raw_current_seq(v.id) end)
      move!(u, v, "A", "B")

      assert {:ok, %{attachments: 1}} = Folders.batch_move(u, v, [marker.id], {:path, "Z"})
      assert at(u, v, "Z/B/x.png") == %{id: att.id, content: "old bytes"}
      assert at(u, v, "B/x.png") == nil
      refute_stale_path(u, v, c)
    end
  end

  # A client older than S4 must be able to reach the head the moved-folder
  # feed serves, and the head must count a folder that holds only an
  # attachment.
  test "feed_head counts a moved folder that holds only an attachment" do
    {:ok, u} = Engram.Fixtures.user_with_dek_fixture()
    v = insert(:vault, user: u)
    {:ok, _} = Notes.create_folder_marker(u, v, "A")
    _ = put_att(u, v, "A/x.png", "old bytes")
    own = Repo.with_tenant!(u.id, fn -> Sync.feed_head(u, v, moved: false) end)
    move!(u, v, "A", "B")

    assert Repo.with_tenant!(u.id, fn -> Sync.feed_head(u, v, moved: false) end) == own
    head = Repo.with_tenant!(u.id, fn -> Sync.feed_head(u, v) end)
    assert head > own
    assert head == Enum.max(Enum.map(feed_rows(u, v, own), & &1.seq))
  end

  defp feed_rows(user, vault, cursor),
    do: Sync.merged_changes_page(user, vault, cursor, nil, 500, :all, nil, []).page

  describe "restore" do
    defp cutoff, do: DateTime.add(DateTime.utc_now(), -1, :day)

    # The tombstone's slot is free by shown path; only the stale key of a
    # row now shown elsewhere holds it.
    test "a tombstone at the moved row's stored path comes back" do
      %{user: u, vault: v} = world()
      gone = put_att(u, v, "A/x.png", "deleted file")
      op = Ecto.UUID.generate()
      {:ok, %{deleted: 1}} = Attachments.batch_delete(u, v, ["A/x.png"], op_id: op)
      moved = put_att(u, v, "A/x.png", "moved file")
      move!(u, v, "A", "B")

      assert {:ok, %{attachments: [%{id: id}], skipped: []}} =
               plan = Attachments.plan_restore(u, v, op, cutoff())

      assert id == gone.id
      {:ok, %{attachments: metas}} = plan

      assert {:ok, %{restored: ["A/x.png"], skipped: []}} =
               Attachments.restore_attachments(u, v, metas)

      assert at(u, v, "A/x.png") == %{id: gone.id, content: "deleted file"}
      assert at(u, v, "B/x.png") == %{id: moved.id, content: "moved file"}
    end

    # The tombstone's stored slot is free, but a moved row is shown there:
    # bringing it back would put two files at one path.
    test "a tombstone at the moved row's shown path is path_taken" do
      %{user: u, vault: v} = world()
      _gone = put_att(u, v, "C/x.png", "deleted file")
      op = Ecto.UUID.generate()
      {:ok, _} = Folders.delete(u, v, "C", recursive: true, op_id: op)
      moved = put_att(u, v, "A/x.png", "moved file")
      move!(u, v, "A", "C")

      assert {:ok, %{attachments: [], skipped: [%{path: "C/x.png", reason: :path_taken}]}} =
               Attachments.plan_restore(u, v, op, cutoff())

      assert at(u, v, "C/x.png") == %{id: moved.id, content: "moved file"}
    end
  end

  describe "folder restore (Folders.restore_op/3)" do
    test "a folder deleted under its moved name comes back whole" do
      %{user: u, vault: v, att: att} = moved_world()
      other = put_att(u, v, "B/y.png", "second file")
      op = Ecto.UUID.generate()
      {:ok, _} = Folders.delete(u, v, "B", recursive: true, op_id: op)
      assert live(v) == []

      assert {:ok, %{attachments: 2, skipped: []}} = Folders.restore_op(u, v, op)
      assert at(u, v, "B/x.png") == %{id: att.id, content: "old bytes"}
      assert at(u, v, "B/y.png") == %{id: other.id, content: "second file"}
      assert at(u, v, "A/x.png") == nil
    end

    # The stale row holding A/x.png by its stored key cannot be repointed
    # (its shown slot B/x.png is another file's): that one tombstone is
    # skipped and reported, every other row of the op comes back.
    test "a row whose slot cannot be settled is skipped, the rest restored" do
      %{user: u, vault: v} = world()
      _gone = put_att(u, v, "A/x.png", "deleted file")
      kept = put_att(u, v, "A/y.png", "restorable file")
      op = Ecto.UUID.generate()
      {:ok, %{deleted: 2}} = Attachments.batch_delete(u, v, ["A/x.png", "A/y.png"], op_id: op)
      moved = put_att(u, v, "A/x.png", "moved file")
      move!(u, v, "A", "B")
      blocker = put_att(u, v, "C/z.png", "blocker")
      {:ok, fk} = Crypto.dek_filter_key(u)

      Repo.query!(
        "UPDATE attachments SET path_hmac = $2, folder_ref_stamp = NULL WHERE id = $1",
        [Ecto.UUID.dump!(blocker.id), Crypto.hmac_field(fk, "B/x.png")]
      )

      assert {:ok, %{attachments: 1, skipped: skipped}} = Folders.restore_op(u, v, op)
      assert skipped == [%{path: "A/x.png", kind: "attachment", reason: :conflict}]
      assert at(u, v, "A/y.png") == %{id: kept.id, content: "restorable file"}
      assert at(u, v, "A/x.png") == nil
      assert Enum.any?(live(v), &(&1.id == moved.id))
    end
  end

  # Rollback / mixed window: rows the way 0.89.0 leaves them, read by D.
  describe "rows written the way 0.89.0 writes them" do
    # 0.89.0 has no `name_key` column nor trigger: a row it wrote before
    # this release's migration has a NULL key until the
    # `attachment_name_key` ledger keys it (its pass is
    # `SET name_stamp = name_stamp`, which fires the trigger). Nothing moves
    # a folder past an unkeyed attachment without cascading it (E's write
    # stop requires every attachment keyed), so these are the two states a
    # D read can meet.
    defp unkey!(att),
      do:
        Repo.query!("UPDATE attachments SET name_key = NULL WHERE id = $1", [
          Ecto.UUID.dump!(att.id)
        ])

    defp ledger!(att),
      do:
        Repo.query!("UPDATE attachments SET name_stamp = name_stamp WHERE id = $1", [
          Ecto.UUID.dump!(att.id)
        ])

    test "keyed by the ledger, then left under an uncascaded move: read at the shown path" do
      %{user: u, vault: v} = world()
      att = put_att(u, v, "A/x.png", "old bytes")
      unkey!(att)
      ledger!(att)
      move!(u, v, "A", "B")

      assert {:ok, [%{path: "B/x.png"}]} = Attachments.list_attachments(u, v)
      assert at(u, v, "B/x.png") == %{id: att.id, content: "old bytes"}
      assert at(u, v, "A/x.png") == nil
    end

    # Regression guard: D's own folder rename cascades attachments.
    test "unkeyed, under D's folder rename: cascaded, read at the new path" do
      %{user: u, vault: v} = world()
      att = put_att(u, v, "A/x.png", "old bytes")
      unkey!(att)
      assert {:ok, _} = Folders.rename(u, v, "A", "B")

      assert {:ok, [%{path: "B/x.png"}]} = Attachments.list_attachments(u, v)
      assert at(u, v, "B/x.png") == %{id: att.id, content: "old bytes"}
      assert at(u, v, "A/x.png") == nil
    end

    # After a D write in a moved vault the stored path is the shown one, so
    # 0.89.0 (a rollback), which reads the stored path key only, finds it.
    test "a D write leaves the stored path 0.89.0 reads" do
      %{user: u, vault: v, att: att} = moved_world()
      _ = put_att(u, v, "B/x.png", "new bytes")
      {:ok, fk} = Crypto.dek_filter_key(u)

      assert [%{id: id, path_hmac: hmac} = row] = live(v)
      assert id == att.id
      assert hmac == Crypto.hmac_field(fk, "B/x.png")
      assert {:ok, %{path: "B/x.png"}} = Crypto.maybe_decrypt_attachment_fields(row, u)
    end
  end
end
