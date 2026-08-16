defmodule Engram.Notes.IdentityTest do
  @moduledoc """
  The `filemeta_v0` map as the AUTHORITY for note paths
  (`docs/context/crdt-identity-authority.md`).

  These pin `Engram.Notes.Identity` directly, because reaching it only through
  rename/delete/folder-rename/batch-move left its most load-bearing behaviours
  untestable: an adversarial review found that the live-ROOM refusal path, the
  id-keyed removal and the `hash` carry could each be replaced with a naive
  implementation and the whole suite would stay green.

  The property that ties them together: **a claim is the commit.** So the
  failures that matter are not "the index is stale" — they are a claim that
  landed for an operation that did not happen, and a claim that was refused
  after the rows had already moved.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexPersistence, CrdtIndexRegistry, Identity}
  alias Yex.Sync.SharedDoc

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "IdentityTest"})

    %{user: user, vault: vault}
  end

  defp note(ctx, path) do
    {:ok, note} = Notes.upsert_note(ctx.user, ctx.vault, %{"path" => path, "content" => "x"})
    note
  end

  defp path_of(ctx, note_id) do
    case Notes.get_note_by_id(ctx.user, ctx.vault, note_id) do
      {:ok, %{path: path}} -> path
      _ -> nil
    end
  end

  # Seed the map the way a client eventually will, then stop the room so the
  # claim under test takes the SNAPSHOT path.
  defp seed_index(ctx, entries) do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
        Enum.each(entries, fn {path, value} -> Yex.Map.set(map, path, value) end)
      end)

    ref = Process.monitor(room)
    :ok = SharedDoc.unobserve(room)
    assert_receive {:DOWN, ^ref, :process, ^room, _}, 5_000
    :ok
  end

  defp entry_for(id), do: %{"note_id" => id}

  # Releases run through Engram.Workers.ReleaseIndexEntries so they commit with
  # the caller's transaction and run after it — the folder-delete paths wrap
  # their cascade, and an inline release there either rolls back with a failing
  # attachment leg or, on the live-room path, does NOT roll back and strands
  # live notes with no entry. Draining here is what the Oban queue does in prod.
  defp drain_releases do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "Engram.Workers.ReleaseIndexEntries" and j.state == "available"
        )
      )

    assert jobs != [], "no release job was enqueued"

    Enum.each(jobs, fn job ->
      assert :ok = perform_job(Engram.Workers.ReleaseIndexEntries, job.args)
    end)

    Repo.delete_all(from(j in Oban.Job, where: j.id in ^Enum.map(jobs, & &1.id)))
    :ok
  end

  defp index_entries(ctx) do
    {:ok, doc} = CrdtIndexPersistence.load_doc(ctx.user, ctx.vault.id)
    doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map()
  end

  defp read_live(room, path) do
    test_pid = self()

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        result = doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.fetch(path)
        send(test_pid, {:live_read, path, result})
      end)

    receive do
      {:live_read, ^path, {:ok, value}} -> value
      {:live_read, ^path, :error} -> nil
    after
      2_000 -> flunk("the live index room never answered a read of #{inspect(path)}")
    end
  end

  describe "a claim is refused rather than displacing" do
    # The map can only see collisions IT records. Every other refusal test here
    # seeds the map; this one proves the ROW check exists, because with an empty
    # map (which is every vault in production) the claim would otherwise
    # succeed, the row write would fail, and the target path would be left
    # permanently unclaimable.
    test "a rename onto a path held by a ROW with no index entry leaves no claim", ctx do
      a = note(ctx, "a.md")
      _b = note(ctx, "b.md")
      seed_index(ctx, [{"a.md", entry_for(a.id)}])

      assert {:error, :conflict} = Notes.rename_note(ctx.user, ctx.vault, "a.md", "b.md")

      entries = index_entries(ctx)

      assert entries["a.md"]["note_id"] == a.id,
             "the note lost its own claim to a rename that was rejected"

      refute Map.has_key?(entries, "b.md"),
             "a rejected rename left a durable claim — b.md is now unclaimable forever"
    end

    test "a claim onto a path another note holds in the MAP is refused", ctx do
      a = note(ctx, "a.md")
      squatter = note(ctx, "elsewhere.md")
      seed_index(ctx, [{"b.md", entry_for(squatter.id)}])

      assert {:error, :conflict} = Identity.claim(ctx.user, ctx.vault.id, [{"b.md", a.id}])

      assert index_entries(ctx)["b.md"]["note_id"] == squatter.id
    end

    # Two claims in ONE call naming one path. Checking each target only against
    # the pre-loop map lets both through, and the second set overwrites the
    # first — whose own entry was already deleted. The loser ends up unclaimed,
    # which is the permanent-deadlock state refusal exists to prevent, and the
    # row-level backstop cannot undo it because a claim is not transactional.
    test "two claims in one call naming the same path refuse the whole batch", ctx do
      a = note(ctx, "X/dup.md")
      b = note(ctx, "Y/dup.md")
      seed_index(ctx, [{"X/dup.md", entry_for(a.id)}, {"Y/dup.md", entry_for(b.id)}])

      assert {:error, :conflict} =
               Identity.claim(ctx.user, ctx.vault.id, [{"Dst/dup.md", a.id}, {"Dst/dup.md", b.id}])

      entries = index_entries(ctx)
      assert entries["X/dup.md"]["note_id"] == a.id
      assert entries["Y/dup.md"]["note_id"] == b.id
      refute Map.has_key?(entries, "Dst/dup.md")
    end

    test "a batch move whose targets collide with each other moves nothing", ctx do
      a = note(ctx, "X/dup.md")
      b = note(ctx, "Y/dup.md")
      seed_index(ctx, [{"X/dup.md", entry_for(a.id)}, {"Y/dup.md", entry_for(b.id)}])

      assert {:error, _} =
               Notes.batch_move_notes(ctx.user, ctx.vault, [a.id, b.id], {:path, "Dst"})

      assert path_of(ctx, a.id) == "X/dup.md"
      assert path_of(ctx, b.id) == "Y/dup.md"

      entries = index_entries(ctx)
      assert entries["X/dup.md"]["note_id"] == a.id
      assert entries["Y/dup.md"]["note_id"] == b.id
    end

    # A note ALREADY AT the target path is a no-op: it claims nothing and never
    # vacates. Counting it as a "mover" made it suppress the collision check for
    # a different note targeting its path, so that note's claim committed, its
    # row write hit the incumbent and rolled back, and the path was left
    # permanently unclaimable — with projection performing the move for real if
    # the incumbent was ever deleted.
    test "a no-op mover does not mask a collision for a real mover", ctx do
      a = note(ctx, "t/n.md")
      b = note(ctx, "y/n.md")
      seed_index(ctx, [{"t/n.md", entry_for(a.id)}, {"y/n.md", entry_for(b.id)}])

      assert {:error, {:conflict, _}} =
               Notes.batch_move_notes(ctx.user, ctx.vault, [a.id, b.id], {:path, "t"})

      assert path_of(ctx, a.id) == "t/n.md"
      assert path_of(ctx, b.id) == "y/n.md"

      entries = index_entries(ctx)

      assert entries["t/n.md"]["note_id"] == a.id,
             "the incumbent lost its own claim to a move that was rejected"

      assert entries["y/n.md"]["note_id"] == b.id
    end

    # Re-claiming a path this note already holds must NOT be read as a
    # collision with itself.
    test "re-claiming a path the same note already holds is a no-op", ctx do
      n = note(ctx, "same.md")
      seed_index(ctx, [{"same.md", entry_for(n.id)}])

      assert :ok = Identity.claim(ctx.user, ctx.vault.id, [{"same.md", n.id}])
      assert index_entries(ctx)["same.md"]["note_id"] == n.id
    end
  end

  describe "removal is id-keyed, never path-keyed" do
    # Every rename test where the map agrees with the rows produces identical
    # output under both implementations. This is the case that separates them:
    # the entry at the old path belongs to a DIFFERENT note, so deleting by path
    # would clobber it. Projection triggers exactly this against itself on its
    # chain case.
    test "a rename does not delete another note's entry sitting at its old path", ctx do
      a = note(ctx, "a.md")
      b = note(ctx, "b.md")

      seed_index(ctx, [{"a.md", entry_for(b.id)}, {"stale/a.md", entry_for(a.id)}])

      assert :ok = Identity.claim(ctx.user, ctx.vault.id, [{"c.md", a.id}])

      entries = index_entries(ctx)
      assert entries["c.md"]["note_id"] == a.id

      assert entries["a.md"]["note_id"] == b.id,
             "path-keyed removal clobbered the entry of a different note"

      refute Map.has_key?(entries, "stale/a.md"),
             "the note's own stale entry should have been dropped"
    end

    test "releasing drops every entry naming the note, and is idempotent", ctx do
      n = note(ctx, "gone.md")
      other = note(ctx, "keep.md")
      seed_index(ctx, [{"gone.md", entry_for(n.id)}, {"keep.md", entry_for(other.id)}])

      assert :ok = Identity.release(ctx.user, ctx.vault.id, [n.id])
      assert :ok = Identity.release(ctx.user, ctx.vault.id, [n.id])

      entries = index_entries(ctx)
      refute Map.has_key?(entries, "gone.md")
      assert entries["keep.md"]["note_id"] == other.id
    end

    # A stale entry naming a dead note is not just `unresolved` noise: it makes
    # that path permanently unclaimable by any LIVE note. At batch/cascade scale
    # that is one reservation per deleted file.
    test "a batch delete releases every note it deleted", ctx do
      a = note(ctx, "bulk/a.md")
      b = note(ctx, "bulk/b.md")
      seed_index(ctx, [{"bulk/a.md", entry_for(a.id)}, {"bulk/b.md", entry_for(b.id)}])

      {:ok, _} = Notes.batch_delete_notes(ctx.user, ctx.vault, [a.id, b.id])
      :ok = drain_releases()

      assert index_entries(ctx) == %{},
             "deleted notes left path reservations nothing can ever claim"
    end

    test "a folder delete releases every note under it", ctx do
      a = note(ctx, "Doomed/a.md")
      b = note(ctx, "Doomed/nested/b.md")
      seed_index(ctx, [{"Doomed/a.md", entry_for(a.id)}, {"Doomed/nested/b.md", entry_for(b.id)}])

      {:ok, matches} = Notes.scan_folders(ctx.user, ctx.vault, ["Doomed"])
      {:ok, _} = Notes.delete_scanned(ctx.user, ctx.vault, matches)
      :ok = drain_releases()

      assert index_entries(ctx) == %{}
    end
  end

  describe "client-written fields survive a server move" do
    # Only `note_id` is the server's to assert. Synthesizing a fresh entry drops
    # whatever the client wrote — invisible today because nothing reads `hash`,
    # and a real regression the moment Engram-obsidian#362/#363 does.
    test "type and hash travel with the note to its new path", ctx do
      n = note(ctx, "old.md")

      seed_index(ctx, [
        {"old.md", %{"note_id" => n.id, "type" => "md", "hash" => "h1"}}
      ])

      assert :ok = Identity.claim(ctx.user, ctx.vault.id, [{"new.md", n.id}])

      assert index_entries(ctx)["new.md"] == %{
               "note_id" => n.id,
               "type" => "md",
               "hash" => "h1"
             }
    end

    # The fields come from the entry being RETIRED, not from whatever happens to
    # sit at the destination — a naive merge of the destination entry would keep
    # the wrong hash.
    test "the carried fields come from the old entry, not the destination", ctx do
      n = note(ctx, "src.md")

      seed_index(ctx, [
        {"src.md", %{"note_id" => n.id, "hash" => "correct"}},
        {"dst.md", %{"note_id" => n.id, "hash" => "stale"}}
      ])

      assert :ok = Identity.claim(ctx.user, ctx.vault.id, [{"dst.md", n.id}])

      assert index_entries(ctx)["dst.md"]["hash"] == "correct"
    end
  end

  describe "the live-room path" do
    # Every other test stops the room first, so they all exercise the snapshot
    # path. `update_doc/2` DISCARDS its fun's return value, so simplifying
    # via_room to ignore the result keeps those green while every conflicting
    # rename by a CONNECTED user silently half-applies — on the path that runs
    # most in prod.
    #
    # No on_exit unobserve: the test process IS the observer, so the room's
    # :DOWN fires auto_exit when it ends. An on_exit callback runs in a separate
    # process afterwards and would call unobserve on a room that has already
    # gone.
    test "a refused claim through a LIVE room fails the rename", ctx do
      n = note(ctx, "a.md")
      squatter = note(ctx, "elsewhere.md")

      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      :ok =
        SharedDoc.update_doc(room, fn doc ->
          doc
          |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
          |> Yex.Map.set("b.md", %{"note_id" => squatter.id})
        end)

      assert {:error, :conflict} = Notes.rename_note(ctx.user, ctx.vault, "a.md", "b.md")

      assert path_of(ctx, n.id) == "a.md"
      assert read_live(room, "b.md")["note_id"] == squatter.id
    end

    # `mutate/2` wraps its writes in `Yex.Doc.transaction(doc, "engram_server", …)`
    # so a cascade reaches observers as ONE update instead of 2N. That origin is
    # threaded into SharedDoc's `broadcast_to_users`, which filters observers by
    # `pid != origin` — a binary never equals a pid, so nobody is filtered out.
    # Nothing asserted that, and it is the single most load-bearing property of
    # the change: if server claims stopped reaching devices, the authority would
    # be silently local-only and every other test here would still pass.
    test "a server claim is broadcast to observing clients", ctx do
      n = note(ctx, "old.md")

      # ensure_observed registers THIS process as an observer, so the frame
      # lands in our mailbox.
      {:ok, _room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      assert {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "old.md", "new.md")

      assert_receive {:yjs, _message, _from}, 2_000

      assert path_of(ctx, n.id) == "new.md"
    end

    test "a claim through a LIVE room lands in the room", ctx do
      n = note(ctx, "old.md")
      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      assert {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "old.md", "new.md")

      assert read_live(room, "new.md")["note_id"] == n.id
      refute read_live(room, "old.md")
    end
  end

  describe "a rotation refuses the claim outright" do
    test "a rename during a DEK rotation fails and moves nothing", ctx do
      n = note(ctx, "rot.md")
      seed_index(ctx, [{"rot.md", entry_for(n.id)}])

      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          set: [dek_rotation_locked_at: DateTime.utc_now()]
        )

      user = Repo.get!(Engram.Accounts.User, ctx.user.id)

      assert {:error, :rotation_in_progress} =
               Notes.rename_note(user, ctx.vault, "rot.md", "moved.md")

      assert path_of(ctx, n.id) == "rot.md"
      assert index_entries(ctx)["rot.md"]["note_id"] == n.id
    end
  end

  describe "projection never claims" do
    # Projection derives rows FROM the map. If it claimed, it would write paths
    # derived from a possibly-superseded snapshot back into the authority it
    # reads — overwriting the map with an older copy of itself. `mutate` is
    # idempotent, so no assertion about ROWS can catch this; only "the authority
    # was not written at all" can.
    test "a projection run does not write the index", ctx do
      n = note(ctx, "Old/p.md")
      seed_index(ctx, [{"New/p.md", entry_for(n.id)}])

      before =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.get(Engram.Notes.VaultIndexState, ctx.vault.id)
        end)
        |> elem(1)
        |> Map.get(:state_ciphertext)

      assert :ok =
               Engram.Workers.ProjectVaultIndex.perform(%Oban.Job{
                 args: %{"user_id" => ctx.user.id, "vault_id" => ctx.vault.id}
               })

      assert path_of(ctx, n.id) == "New/p.md"

      after_run =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.get(Engram.Notes.VaultIndexState, ctx.vault.id)
        end)
        |> elem(1)
        |> Map.get(:state_ciphertext)

      assert after_run == before,
             "projection wrote to the authority it derives from — that is a feedback loop"
    end
  end
end
