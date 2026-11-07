defmodule Engram.Folders.LiveRefTest do
  # #2485 review r3: no writer may leave a live note or attachment naming a
  # DEAD folder row (it would be in no folder listing and no count, and no
  # drift index would ever see it). `folder_ref_live_only` (20261107090000)
  # turns such a reference into NULL, the drift every reader places; the
  # folder-write lock keeps FolderTable's heal out of a rename or batch move
  # without blocking anyone else.
  use Engram.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Attachments, Crypto, Notes, Repo, Vaults}
  alias Engram.DataMigrations.FolderTable
  alias Engram.FolderRows

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp put_note(u, v, path) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => "# T\n\nb"}, actor: "api")
    n
  end

  defp put_att(u, v, path) do
    {:ok, a} =
      Attachments.upsert_attachment(u, v, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    a
  end

  defp page_ids(u, v, folder) do
    {:ok, %{notes: notes}} = Notes.list_notes_in_folder_page(u, v, folder)
    Enum.map(notes, & &1.id)
  end

  defp count(u, v, folder) do
    {:ok, counts} = Notes.list_folders_with_counts(u, v)
    Enum.find_value(counts, 0, &(&1.folder == folder && &1.count))
  end

  defp stamp(att_id) do
    %{rows: [[ref, stamp, nonce]]} =
      Repo.query!(
        "SELECT folder_ref_id, folder_ref_stamp, path_nonce FROM attachments WHERE id = $1",
        [dump(att_id)]
      )

    {ref, stamp == nonce}
  end

  describe "a plain writer setting a dead reference" do
    test "a note's and an attachment's become NULL, and both stay listed", %{user: u, vault: v} do
      n = put_note(u, v, "D/n.md")
      a = put_att(u, v, "D/a.png")
      row = FolderRows.tree(u)["D"].id
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(row)])

      Repo.query!("UPDATE notes SET folder_ref_id = $1 WHERE id = $2", [dump(row), dump(n.id)])

      Repo.query!(
        "UPDATE attachments SET folder_ref_id = $1, folder_ref_stamp = path_nonce WHERE id = $2",
        [dump(row), dump(a.id)]
      )

      assert FolderRows.ref("notes", n.id) == nil
      assert stamp(a.id) == {nil, false}
      assert n.id in page_ids(u, v, "D")
      assert count(u, v, "D") == 1
      assert {:ok, [%{path: "D/a.png"}]} = Attachments.list_in_folder(u, v, "D")
    end

    test "control: a live reference is kept", %{user: u, vault: v} do
      n = put_note(u, v, "L/n.md")
      row = FolderRows.tree(u)["L"].id
      Repo.query!("UPDATE notes SET folder_ref_id = $1 WHERE id = $2", [dump(row), dump(n.id)])
      assert FolderRows.ref("notes", n.id) == row
    end
  end

  # The reviewer's probe S1: FolderTable creates the row for a drift note,
  # the folder row dies before FolderTable points the note (and a stale
  # attachment) at it. Red before the trigger: both named the dead row and
  # were in no listing and no count.
  test "FolderTable pointing at a row that died meanwhile leaves both listed", ctx do
    %{user: u, vault: v} = ctx
    n = put_note(u, v, "A/C/n.md")
    a = put_att(u, v, "A/C/a.png")
    Repo.query!("DELETE FROM folders WHERE id = $1", [dump(FolderRows.tree(u)["A/C"].id)])

    Repo.query!(
      "UPDATE attachments SET folder_ref_id = NULL, folder_ref_stamp = NULL WHERE id = $1",
      [dump(a.id)]
    )

    {:ok, fk} = Crypto.dek_filter_key(u)
    leaf = Crypto.hmac_field(fk, "A/C")
    pid = self()
    id = "kill-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:engram, :repo, :query],
      fn _, _, meta, _ ->
        if self() == pid and not Process.get(:killed, false) and
             (meta[:query] || "") =~ ~r/INSERT INTO "?folders/ do
          Process.put(:killed, true)

          Repo.query!(
            "UPDATE folders SET deleted_at = now() " <>
              "WHERE vault_id = $1 AND full_path_hmac = $2 AND deleted_at IS NULL",
            [dump(v.id), leaf]
          )
        end
      end,
      nil
    )

    try do
      FolderTable.run_pass(user_ids: [u.id])
      assert Process.get(:killed), "FolderTable created no folder row"
    after
      :telemetry.detach(id)
    end

    ref = FolderRows.ref("notes", n.id)
    assert ref == nil or FolderRows.row(ref).deleted_at == nil
    assert n.id in page_ids(u, v, "A/C")
    assert count(u, v, "A/C") == 1
    assert {:ok, [%{path: "A/C/a.png"}]} = Attachments.list_in_folder(u, v, "A/C")
  end

  test "the trigger is installed and enabled on notes and attachments" do
    assert %{rows: rows} =
             Repo.query!(
               "SELECT tgrelid::regclass::text, tgenabled::text FROM pg_trigger " <>
                 "WHERE tgname IN ('notes_folder_ref_live_only', 'attachments_folder_ref_live_only') " <>
                 "ORDER BY 1"
             )

    assert rows == [["attachments", "O"], ["notes", "O"]]
  end

  # Two real connections (`unboxed_run/2`): locks across sessions cannot be
  # seen inside the one sandbox connection. A committed user and vault,
  # deleted after.
  describe "the folder-write lock" do
    setup do
      {user, vault} =
        Sandbox.unboxed_run(Repo, fn ->
          # A unique email: this row is committed, so a factory sequence that
          # restarts each run would collide with one a crashed run left.
          user = insert(:user, email: "live-ref-#{Ecto.UUID.generate()}@test.local")
          {user, insert(:vault, user: user)}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DELETE FROM vaults WHERE id = $1", [dump(vault.id)])
          Repo.query!("DELETE FROM users WHERE id = $1", [dump(user.id)])
        end)
      end)

      %{owner: user, locked_vault: vault}
    end

    # Runs `fun` in a transaction on its own connection until told to stop.
    defp hold(fun) do
      parent = self()

      task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              fun.()
              send(parent, :held)

              receive do
                :release -> :ok
              end
            end)
          end)
        end)

      assert_receive :held, 5_000
      task
    end

    defp release(task) do
      send(task.pid, :release)
      Task.await(task)
    end

    defp on_own_connection(fun) do
      Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> Repo.transaction(fun) end) end)
      |> Task.await(10_000)
    end

    test "the heal skips the user while a folder write holds a vault", ctx do
      %{owner: u, locked_vault: v} = ctx
      task = hold(fn -> Vaults.lock_folder_writes!(v.id) end)

      result =
        on_own_connection(fn ->
          try do
            Vaults.try_folder_write_locks!(Repo, u.id)
          rescue
            e in Postgrex.Error -> e.postgres.code
          end
        end)

      release(task)
      assert result == {:ok, :lock_not_available}
      # Free again once the write commits.
      assert on_own_connection(fn -> Vaults.try_folder_write_locks!(Repo, u.id) end) == {:ok, :ok}
    end

    test "a heal step blocks no writer of the vault", %{owner: u, locked_vault: v} do
      task =
        hold(fn ->
          :ok = Vaults.lock_user_vaults_nowait!(Repo, u.id)
          :ok = Vaults.try_folder_write_locks!(Repo, u.id)
        end)

      # The writer's vault seq lock, with a short lock_timeout: it would raise
      # if the heal's locks conflicted with it.
      result =
        on_own_connection(fn ->
          Repo.query!("SET LOCAL lock_timeout = '1s'")
          Vaults.lock_seq(v.id)
        end)

      release(task)
      assert result == {:ok, :ok}
    end
  end
end
