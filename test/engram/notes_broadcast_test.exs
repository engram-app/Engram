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

    # Receivers relocate the note's id to the new path (upsert) BEFORE they
    # see the old-path delete, so the delete reads as a relocation leg (id
    # lives elsewhere) instead of tearing the note's CRDT room down by id.
    # Patterns here do NOT discriminate on event_type, so the two
    # assert_receives capture mailbox order and enforce upsert-before-delete.
    test "cascade broadcasts the new-path upsert before the old-path delete", %{
      user: user,
      vault: vault
    } do
      {:ok, _child} =
        Notes.upsert_note(user, vault, %{
          "path" => "Old/Child.md",
          "content" => "# Child",
          "mtime" => 1.0
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert {:ok, 1} = Notes.rename_folder(user, vault, "Old", "New")

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: first}
      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: second}

      assert first["event_type"] == "upsert"
      assert second["event_type"] == "delete"
    end

    # e2e test_34 "received=yes materialized=no": the cascade used to
    # broadcast meta-projected rows (content never decrypted), so the upsert
    # carried NO inline body and receivers waited ~30-60s for a pull to
    # materialize the renamed path. Fix: decrypt each renamed note's body and
    # ship it inline, exactly like the single-note rename. The body MUST be
    # the note's REAL content (matching content_hash) — never fabricated `""`
    # (that shipped a 0-byte file that read as converged forever, #863).
    test "cascade upsert carries the renamed note's real content inline", %{
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
        payload: %{"event_type" => "upsert"} = payload
      }

      assert payload["content"] == "# Child"
      assert payload["content_hash"] == child.content_hash
      assert is_binary(payload["content_hash"])
    end

    # #976: the old-path delete leg used to broadcast without the note id,
    # forcing receivers to resolve by path mid-relocation — the ambiguity
    # window the folder-rename resurrection bug lived in. The note still
    # exists (same id, new path), so receivers can correlate delete+upsert
    # by id and treat the pair as a relocation.
    test "delete broadcast for the old path carries the moved note's id", %{
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
        payload: %{"event_type" => "delete", "path" => "Old/Child.md"} = payload
      }

      assert payload["id"] == child.id
    end
  end

  describe "rename_note/4 delete-leg broadcast (#976)" do
    # Sibling of the folder-rename cascade leg: the single-note rename's
    # old-path delete broadcast must also carry the moved note's id so
    # receivers correlate the delete+upsert pair as a relocation instead of
    # resolving by path mid-move. Without this assertion the :1320 leg could
    # silently regress to nil and stay green.
    test "delete broadcast for the old path carries the moved note's id", %{
      user: user,
      vault: vault
    } do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Old.md",
          "content" => "# Old",
          "mtime" => 1.0
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, _} = Notes.rename_note(user, vault, "Old.md", "New.md")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "path" => "Old.md"} = payload
      }

      assert payload["id"] == note.id
    end

    # Same relocation ordering as the folder-rename cascade: the receiver
    # must relocate the note's id to the new path (upsert) BEFORE the
    # old-path delete, or the delete tears the note's CRDT room down by id
    # before the new path can materialize from it.
    test "broadcasts the new-path upsert before the old-path delete", %{
      user: user,
      vault: vault
    } do
      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Old.md",
          "content" => "# Old",
          "mtime" => 1.0
        })

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, _} = Notes.rename_note(user, vault, "Old.md", "New.md")

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: first}
      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: second}

      assert first["event_type"] == "upsert"
      assert second["event_type"] == "delete"
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

    # Phase E2 rename-as-move via crdt_create: a LIVE id re-pushed at a new free
    # path must fan the OLD-path delete to peers too, not just the new-path
    # upsert — otherwise a web receiver (no local mirror) keeps the note in the
    # old folder forever (tree-ops-sync.spec.ts "move note propagates"). Same
    # upsert-before-delete ordering as the REST rename delete leg.
    test "relocating a LIVE id broadcasts the old-path delete after the new-path upsert",
         %{user: user, vault: vault} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(user, vault, id, "Source/mover.md")

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, moved} = Notes.genesis_crdt_note(user, vault, id, "Dest/mover.md")
      assert moved.id == id
      assert moved.path == "Dest/mover.md"

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: first}
      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: second}

      assert first["event_type"] == "upsert"
      assert first["path"] == "Dest/mover.md"
      assert second["event_type"] == "delete"
      assert second["path"] == "Source/mover.md"
      assert second["id"] == id
    end
  end

  describe "note_changed delete broadcast (self-echo attribution — 2026-07-08 wipe)" do
    test "no-op delete of an unknown path emits NO broadcast (#971)", %{
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert :ok = Notes.delete_note(user, vault, "Ghost/Never Existed.md")

      refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100
    end

    test "delete broadcast carries the caller's origin device_id (#970)", %{
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "del.md", "content" => "# D", "mtime" => 1.0})

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      device_id = Ecto.UUID.generate()

      assert :ok = Notes.delete_note(user, vault, "del.md", origin_device_id: device_id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "path" => "del.md"} = payload
      }

      assert payload["device_id"] == device_id
    end

    test "delete broadcast omits device_id when the caller has none", %{
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "del2.md", "content" => "# D", "mtime" => 1.0})

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert :ok = Notes.delete_note(user, vault, "del2.md")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "path" => "del2.md"} = payload
      }

      refute Map.has_key?(payload, "device_id")
    end
  end
end
