defmodule Engram.NotesBroadcastTest do
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  describe "note_changed upsert broadcast (protocol rev dual-field)" do
    test "carries BOTH content and content_hash for the transition release", %{
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "# A",
          "mtime" => 1.0
        })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: payload
      }

      assert payload["event_type"] == "upsert"
      assert payload["content"] == "# A"
      assert payload["content_hash"] == note.content_hash
      assert is_binary(payload["content_hash"])
    end

    test "broadcast_from: pid excludes that subscriber", %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, _} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "b.md", "content" => "# B", "mtime" => 1.0},
          broadcast_from: self()
        )

      refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100
    end
  end

  describe "rename_folder/4 cascade broadcast" do
    test "upsert broadcast for a renamed child carries the note id and new path", %{
      user: user,
      vault: vault
    } do
      {:ok, child} =
        Notes.upsert_note(user, vault, %{
          "path" => "Old/Child.md",
          "content" => "# Child",
          "mtime" => 1.0
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert {:ok, 1} = Notes.rename_folder(user, vault, "Old", "New")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete"}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "upsert"} = payload
      }

      assert payload["id"] == child.id
      assert payload["path"] == "New/Child.md"
    end
  end
end
