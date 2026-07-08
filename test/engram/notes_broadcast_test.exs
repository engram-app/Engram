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

    test "carries a w3c traceparent when the upsert runs inside a span", %{
      user: user,
      vault: vault
    } do
      require OpenTelemetry.Tracer, as: Tracer

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      Tracer.with_span "req" do
        {:ok, _} =
          Notes.upsert_note(user, vault, %{
            "path" => "c.md",
            "content" => "# C",
            "mtime" => 1.0
          })
      end

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: payload}
      assert payload.traceparent =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]\z/
    end

    test "traceparent is nil when no span is active", %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "d.md", "content" => "# D", "mtime" => 1.0})

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: payload}
      assert payload.traceparent == nil
    end
  end

  describe "rapid successive upserts broadcast (Engram#944)" do
    test "two upserts to the same path with different content each broadcast a note_changed upsert",
         %{user: user, vault: vault} do
      {:ok, _base} =
        Notes.upsert_note(user, vault, %{
          "path" => "canvas.canvas",
          "content" => "base",
          "mtime" => 1.0
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      # Fire the second upsert immediately after the first — no artificial
      # delay — to mirror the e2e repro's back-to-back rapid writes.
      {:ok, modified} =
        Notes.upsert_note(user, vault, %{
          "path" => "canvas.canvas",
          "content" => "modified",
          "mtime" => 1.001
        })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "upsert", "content_hash" => hash}
      }

      assert hash == modified.content_hash
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

  describe "delete_folder/3 empty-folder broadcast" do
    test "deleting an empty folder still broadcasts a note_changed delete event", %{
      user: user,
      vault: vault
    } do
      {:ok, _marker} = Notes.create_folder_marker(user, vault, "Empty")

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert {:ok, %{deleted: 1}} = Notes.delete_folder(user, vault, "Empty")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "path" => "Empty"}
      }
    end
  end

  describe "id-keyed rename move broadcast" do
    test "moving a tombstoned id to a new path broadcasts a new-path upsert (unchanged content)",
         %{user: user, vault: vault} do
      id = Ecto.UUID.generate()

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "A.md",
          "content" => "# Rename\nbody",
          "id" => id
        })

      :ok = Notes.delete_note(user, vault, "A.md")

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      # Re-push the SAME id at a new path (the rename's new-path push). Content
      # is identical, so without the move's unconditional broadcast the
      # hash-equal guard would suppress this — stranding peers with the delete
      # of A.md but never an upsert of B.md.
      {:ok, moved} =
        Notes.upsert_note(user, vault, %{
          "path" => "B.md",
          "content" => "# Rename\nbody",
          "id" => id
        })

      assert moved.id == id
      assert moved.path == "B.md"

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "upsert", "path" => "B.md", "id" => ^id}
      }
    end
  end
end
