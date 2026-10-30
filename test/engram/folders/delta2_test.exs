defmodule Engram.Folders.Delta2Test do
  # Review of the batch-resolve change: a restore chunk resolves its folders up
  # front (outside the per-row savepoints), and marker ids that are not UUIDs
  # are "not found", not a crash.
  use Engram.DataCase, async: false

  alias Engram.{Folders, Notes, Repo}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    Application.put_env(:engram, :restore_chunk, 10)
    on_exit(fn -> Application.delete_env(:engram, :restore_chunk) end)
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  test "a row that collides inside its savepoint does not strand the next one's folder ref", %{
    user: u,
    vault: v
  } do
    a = put_note(u, v, "D/a.md")
    b = put_note(u, v, "D/b.md")
    op = Ecto.UUID.generate()
    assert {:ok, %{notes: 2}} = Folders.delete(u, v, "D", recursive: true, op_id: op)

    {:ok, plan} = Notes.plan_restore(u, v, op, DateTime.add(DateTime.utc_now(), -1, :day))
    assert length(plan.notes) == 2

    # A live row takes a.md's path after the plan, with no index claim: the
    # restore of a.md hits the unique index inside its savepoint.
    Engram.Fixtures.insert_note!(u, v, %{path: "D/a.md", content: "x"})

    assert {:ok, %{restored: restored}} = Notes.restore_notes(u, v, op, plan.notes)
    assert Enum.map(restored, & &1.id) == [b.id]
    _ = a

    %{rows: [[ref, live?]]} =
      Repo.query!(
        "SELECT n.folder_ref_id, f.id IS NOT NULL AND f.deleted_at IS NULL FROM notes n " <>
          "LEFT JOIN folders f ON f.id = n.folder_ref_id WHERE n.id = $1",
        [Ecto.UUID.dump!(b.id)]
      )

    assert ref
    assert live?
  end

  describe "resolve_folder_markers/3" do
    test "an invalid id is not_found, in input order", %{user: u, vault: v} do
      {:ok, m1} = Notes.create_folder_marker(u, v, "One")
      {:ok, m2} = Notes.create_folder_marker(u, v, "Two")

      assert {:error, {:not_found, "not-a-uuid"}} =
               Notes.resolve_folder_markers(u, v, [m1.id, "not-a-uuid", m2.id])

      missing = Ecto.UUID.generate()

      assert {:error, {:not_found, ^missing}} =
               Notes.resolve_folder_markers(u, v, [m1.id, missing, "bad"])

      assert {:ok, folders} = Notes.resolve_folder_markers(u, v, [m1.id, m2.id])
      assert Enum.sort(folders) == ["One", "Two"]
    end
  end
end
