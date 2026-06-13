defmodule Engram.NotesBatchUpsertTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes
  alias Engram.UsageMeters

  setup do
    user = insert(:user)

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})

    %{user: user, vault: vault}
  end

  describe "batch_upsert_notes/3 — inserts" do
    test "inserts new notes and returns per-note ok results in input order", %{
      user: user,
      vault: vault
    } do
      notes = [
        %{"path" => "a.md", "content" => "# A", "mtime" => 1.0},
        %{"path" => "sub/b.md", "content" => "# B", "mtime" => 2.0}
      ]

      assert {:ok, %{results: [r1, r2]}} = Notes.batch_upsert_notes(user, vault, notes)

      assert %{path: "a.md", status: :ok, version: 1} = r1
      assert %{path: "sub/b.md", status: :ok, version: 1} = r2
      assert is_binary(r1.id) and is_binary(r2.id)
      assert is_binary(r1.content_hash)

      assert {:ok, note} = Notes.get_note(user, vault, "a.md")
      assert note.content == "# A"
      assert note.title == "A"

      assert {:ok, nested} = Notes.get_note(user, vault, "sub/b.md")
      assert nested.folder == "sub"
    end

    test "increments the notes meter once by the inserted count", %{user: user, vault: vault} do
      notes = for i <- 1..3, do: %{"path" => "n#{i}.md", "content" => "x", "mtime" => 1.0}

      assert {:ok, _} = Notes.batch_upsert_notes(user, vault, notes)
      assert UsageMeters.notes_count(user.id) == 3
    end

    test "honors a client-supplied uuid on insert", %{user: user, vault: vault} do
      client_id = Ecto.UUID.generate()

      assert {:ok, %{results: [r]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "c.md", "content" => "x", "mtime" => 1.0, "id" => client_id}
               ])

      assert r.id == client_id
    end

    test "enqueues one embed job per changed note", %{user: user, vault: vault} do
      notes = [
        %{"path" => "a.md", "content" => "alpha", "mtime" => 1.0},
        %{"path" => "b.md", "content" => "beta", "mtime" => 1.0}
      ]

      assert {:ok, %{results: results}} = Notes.batch_upsert_notes(user, vault, notes)
      ids = Enum.map(results, & &1.id)

      jobs = all_enqueued(worker: Engram.Workers.EmbedNote)
      assert Enum.sort(Enum.map(jobs, & &1.args["note_id"])) == Enum.sort(ids)
    end
  end

  describe "batch_upsert_notes/3 — updates" do
    test "updates existing notes, bumping version", %{user: user, vault: vault} do
      {:ok, existing} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v1", "mtime" => 1.0})

      assert {:ok, %{results: [r]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "a.md", "content" => "v2", "mtime" => 2.0}
               ])

      assert %{path: "a.md", status: :ok, version: 2} = r
      assert r.id == existing.id

      assert {:ok, note} = Notes.get_note(user, vault, "a.md")
      assert note.content == "v2"
      assert UsageMeters.notes_count(user.id) == 1
    end

    test "skips the embed job when content is unchanged", %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "same", "mtime" => 1.0})

      # Drain jobs enqueued by the seed upsert.
      seed_jobs = all_enqueued(worker: Engram.Workers.EmbedNote)

      assert {:ok, %{results: [%{status: :ok}]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "a.md", "content" => "same", "mtime" => 2.0}
               ])

      assert all_enqueued(worker: Engram.Workers.EmbedNote) == seed_jobs
    end

    test "mixed insert + update in one batch", %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "old.md", "content" => "v1", "mtime" => 1.0})

      notes = [
        %{"path" => "old.md", "content" => "v2", "mtime" => 2.0},
        %{"path" => "new.md", "content" => "n", "mtime" => 2.0}
      ]

      assert {:ok, %{results: [r_old, r_new]}} = Notes.batch_upsert_notes(user, vault, notes)
      assert %{status: :ok, version: 2} = r_old
      assert %{status: :ok, version: 1} = r_new
      assert UsageMeters.notes_count(user.id) == 2
    end
  end

  describe "batch_upsert_notes/3 — conflicts and errors" do
    test "stale client version yields a conflict entry carrying the server note", %{
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v1", "mtime" => 1.0})

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v2", "mtime" => 2.0})

      notes = [
        %{"path" => "a.md", "content" => "mine", "mtime" => 3.0, "version" => 1},
        %{"path" => "b.md", "content" => "ok", "mtime" => 3.0}
      ]

      assert {:ok, %{results: [conflict, ok]}} = Notes.batch_upsert_notes(user, vault, notes)

      assert %{path: "a.md", status: :conflict, server_note: server_note} = conflict
      assert server_note.content == "v2"
      assert server_note.version == 2
      assert server_note.path == "a.md"

      # Conflict must not block the rest of the batch.
      assert %{path: "b.md", status: :ok} = ok
      assert {:ok, _} = Notes.get_note(user, vault, "b.md")

      # Server content untouched by the stale push.
      assert {:ok, note} = Notes.get_note(user, vault, "a.md")
      assert note.content == "v2"
    end

    test "blank path yields a per-note error entry without failing the batch", %{
      user: user,
      vault: vault
    } do
      notes = [
        %{"path" => "", "content" => "x", "mtime" => 1.0},
        %{"path" => "ok.md", "content" => "x", "mtime" => 1.0}
      ]

      assert {:ok, %{results: [bad, good]}} = Notes.batch_upsert_notes(user, vault, notes)
      assert %{path: "", status: :error} = bad
      assert %{path: "ok.md", status: :ok} = good
    end

    test "duplicate paths within a batch error after the first occurrence", %{
      user: user,
      vault: vault
    } do
      notes = [
        %{"path" => "dup.md", "content" => "first", "mtime" => 1.0},
        %{"path" => "dup.md", "content" => "second", "mtime" => 2.0}
      ]

      assert {:ok, %{results: [first, second]}} = Notes.batch_upsert_notes(user, vault, notes)
      assert %{status: :ok} = first
      assert %{status: :error} = second

      assert {:ok, note} = Notes.get_note(user, vault, "dup.md")
      assert note.content == "first"
    end

    test "duplicate client ids within a batch error after the first occurrence", %{
      user: user,
      vault: vault
    } do
      shared_id = Ecto.UUID.generate()

      notes = [
        %{"path" => "one.md", "content" => "x", "mtime" => 1.0, "id" => shared_id},
        %{"path" => "two.md", "content" => "x", "mtime" => 1.0, "id" => shared_id}
      ]

      assert {:ok, %{results: [first, second]}} = Notes.batch_upsert_notes(user, vault, notes)
      assert %{status: :ok} = first
      assert %{status: :error} = second

      assert {:ok, _} = Notes.get_note(user, vault, "one.md")
      assert {:error, :not_found} = Notes.get_note(user, vault, "two.md")
    end

    test "client id colliding with an existing row degrades to a per-note error", %{
      user: user,
      vault: vault
    } do
      {:ok, existing} =
        Notes.upsert_note(user, vault, %{"path" => "taken.md", "content" => "x", "mtime" => 1.0})

      notes = [
        %{"path" => "thief.md", "content" => "x", "mtime" => 1.0, "id" => existing.id},
        %{"path" => "fine.md", "content" => "x", "mtime" => 1.0}
      ]

      assert {:ok, %{results: [collided, ok]}} = Notes.batch_upsert_notes(user, vault, notes)
      assert %{path: "thief.md", status: :error} = collided
      assert %{path: "fine.md", status: :ok} = ok

      # The meter only counts rows that actually landed.
      assert UsageMeters.notes_count(user.id) == 2
      assert {:error, :not_found} = Notes.get_note(user, vault, "thief.md")
    end

    test "whole batch is rejected when inserts would exceed the notes cap", %{
      user: user,
      vault: vault
    } do
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 2})

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "x", "mtime" => 1.0})

      notes = [
        %{"path" => "b.md", "content" => "x", "mtime" => 1.0},
        %{"path" => "c.md", "content" => "x", "mtime" => 1.0}
      ]

      assert {:error, {:notes_cap_reached, 2, 1}} = Notes.batch_upsert_notes(user, vault, notes)

      # Nothing committed.
      assert {:error, :not_found} = Notes.get_note(user, vault, "b.md")
      assert UsageMeters.notes_count(user.id) == 1
    end

    test "updates are exempt from the notes cap", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 1})

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v1", "mtime" => 1.0})

      assert {:ok, %{results: [%{status: :ok, version: 2}]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "a.md", "content" => "v2", "mtime" => 2.0}
               ])
    end
  end

  describe "batch_upsert_notes/3 — broadcast digest" do
    test "emits one notes.batch digest instead of per-note note_changed", %{
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      notes = [
        %{"path" => "a.md", "content" => "# A", "mtime" => 1.0},
        %{"path" => "b.md", "content" => "# B", "mtime" => 2.0}
      ]

      assert {:ok, %{results: results}} = Notes.batch_upsert_notes(user, vault, notes)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "notes.batch",
        payload: %{op: "upsert", notes: digest}
      }

      assert length(digest) == 2
      [first | _] = Enum.sort_by(digest, & &1["path"])
      assert first["path"] == "a.md"
      assert first["id"] == Enum.find(results, &(&1.path == "a.md")).id
      assert first["version"] == 1
      assert is_binary(first["content_hash"])
      assert first["title"] == "A"
      refute Map.has_key?(first, "content")

      refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100
    end

    test "conflict and error entries are excluded from the digest", %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v1", "mtime" => 1.0})

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      notes = [
        %{"path" => "a.md", "content" => "stale", "mtime" => 2.0, "version" => 99},
        %{"path" => "ok.md", "content" => "x", "mtime" => 2.0}
      ]

      assert {:ok, _} = Notes.batch_upsert_notes(user, vault, notes)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "notes.batch",
        payload: %{op: "upsert", notes: [only]}
      }

      assert only["path"] == "ok.md"
    end

    test "an all-conflict batch emits no digest", %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v1", "mtime" => 1.0})

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert {:ok, %{results: [%{status: :conflict}]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "a.md", "content" => "stale", "mtime" => 2.0, "version" => 99}
               ])

      refute_receive %Phoenix.Socket.Broadcast{event: "notes.batch"}, 100
    end

    test "broadcasts vault_populated when the batch populates an empty vault", %{
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("user:#{user.id}")

      assert {:ok, _} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "first.md", "content" => "x", "mtime" => 1.0},
                 %{"path" => "second.md", "content" => "x", "mtime" => 1.0}
               ])

      assert_receive %Phoenix.Socket.Broadcast{
        event: "vault_populated",
        payload: %{vault_id: vault_id}
      }

      assert vault_id == vault.id
    end

    test "does not broadcast vault_populated for an already-populated vault", %{
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "seed.md", "content" => "x", "mtime" => 1.0})

      EngramWeb.Endpoint.subscribe("user:#{user.id}")

      assert {:ok, _} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "more.md", "content" => "x", "mtime" => 1.0}
               ])

      refute_receive %Phoenix.Socket.Broadcast{event: "vault_populated"}, 100
    end
  end

  describe "batch_upsert_notes/3 — edges" do
    test "empty list returns empty results", %{user: user, vault: vault} do
      assert {:ok, %{results: []}} = Notes.batch_upsert_notes(user, vault, [])
    end

    test "path traversal is sanitized like the single-note path", %{user: user, vault: vault} do
      assert {:ok, %{results: [r]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "../escape.md", "content" => "x", "mtime" => 1.0}
               ])

      assert r.status == :ok
      # Sanitizer strips the traversal — note lands at a safe path. The
      # result echoes the input path for correlation and exposes the
      # canonical path separately so clients can rename local files.
      assert r.path == "../escape.md"
      assert r.server_path == "escape.md"
      assert {:ok, _} = Notes.get_note(user, vault, "escape.md")
    end
  end
end
