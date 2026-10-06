defmodule Engram.NotesRecentTest do
  use Engram.DataCase, async: true
  alias Engram.Notes

  test "newest updated first, limited, notes only, own vault only" do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    other = insert(:vault, user: user)

    for {p, t} <- [{"old.md", 1.0}, {"mid.md", 2.0}, {"new.md", 3.0}] do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => t},
          actor: "api"
        )

      Process.sleep(2)
    end

    {:ok, _} =
      Notes.upsert_note(
        user,
        other,
        %{"path" => "elsewhere.md", "content" => "x", "mtime" => 9.0},
        actor: "api"
      )

    assert {:ok, notes} = Notes.list_recent_notes(user, vault, 2)
    assert Enum.map(notes, & &1.path) == ["new.md", "mid.md"]
  end
end
