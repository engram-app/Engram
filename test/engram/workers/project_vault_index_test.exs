defmodule Engram.Workers.ProjectVaultIndexTest do
  @moduledoc """
  Projection of `filemeta_v0` onto the `notes` path columns (#1151 step 2).

  This is the half of #1151 that makes a client-owned index usable by everything
  that is NOT the CRDT: REST, search, MCP. The server never reads Yjs state to
  answer "what is this note's path" — it reads the ordinary column, exactly as
  `CrdtCheckpoint` projects note CONTENT for the same reason.

  ## The property that matters most

  Projection is **per entry, and never acts on absence.** No client writes the
  index yet (Engram-obsidian#362), so in prod today it is always empty — and an
  implementation that reconciled by absence would read that as "delete every
  note in the vault". Being additive-corrective is what makes shipping this
  dormant safe rather than terrifying.

  It also means projection can never delete. A note the index does not mention
  is a note projection has no opinion about.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry}
  alias Engram.Workers.ProjectVaultIndex
  alias Yex.Sync.SharedDoc

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "ProjectionTest"})

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

  # Seed the vault's index and persist it, the way a client eventually will.
  defp seed_index(ctx, entries) do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
        Enum.each(entries, fn {path, id} -> Yex.Map.set(map, path, %{"note_id" => id}) end)
      end)

    ref = Process.monitor(room)
    :ok = SharedDoc.unobserve(room)
    assert_receive {:DOWN, ^ref, :process, ^room, _}, 5_000
    :ok
  end

  # update_doc/2 returns :ok and discards the fun's value, so a read has to be
  # posted back out of the room process.
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

  # The PERSISTED entries, which is what a claim has to land in when no room is
  # live — reading the live room instead would not prove the snapshot was written.
  defp index_entries(ctx) do
    {:ok, doc} = Engram.Notes.CrdtIndexPersistence.load_doc(ctx.user, ctx.vault.id)
    doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map()
  end

  defp tenant_index_ciphertext(ctx) do
    {:ok, row} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.get(Engram.Notes.VaultIndexState, ctx.vault.id)
      end)

    row && row.state_ciphertext
  end

  defp run(ctx) do
    perform_job(ProjectVaultIndex, %{"user_id" => ctx.user.id, "vault_id" => ctx.vault.id})
  end

  describe "corrective renames" do
    test "an entry whose path differs from the row moves the note", ctx do
      n = note(ctx, "Old/place.md")
      seed_index(ctx, [{"New/place.md", n.id}])

      assert :ok = run(ctx)
      assert path_of(ctx, n.id) == "New/place.md"
    end

    # The no-churn guarantee comes from rename_note/4's {:no_change, note}
    # branch, not from a guard in the worker — this pins the PROPERTY, which is
    # what survives either implementation.
    test "an entry that already agrees changes nothing", ctx do
      n = note(ctx, "Settled/note.md")
      {:ok, before} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
      seed_index(ctx, [{"Settled/note.md", n.id}])

      assert :ok = run(ctx)

      {:ok, unchanged} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)

      assert unchanged.path == before.path
      assert unchanged.version == before.version, "an agreeing entry must not churn the row"
    end
  end

  describe "never acts on absence" do
    # THE safety property. In prod today the index is empty for every vault,
    # because no client writes it yet. A projection that reconciled by absence
    # would read that as "this vault has no files".
    test "an empty index leaves every note alone", ctx do
      a = note(ctx, "keep/a.md")
      b = note(ctx, "keep/b.md")
      seed_index(ctx, [])

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "keep/a.md"
      assert path_of(ctx, b.id) == "keep/b.md"
    end

    test "a note the index does not mention is untouched", ctx do
      mentioned = note(ctx, "Old/mentioned.md")
      unmentioned = note(ctx, "quiet/unmentioned.md")

      seed_index(ctx, [{"New/mentioned.md", mentioned.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, mentioned.id) == "New/mentioned.md"

      assert path_of(ctx, unmentioned.id) == "quiet/unmentioned.md",
             "projection has no opinion about a note the index never mentions"
    end

    test "a vault with no snapshot at all is a no-op, not an error", ctx do
      n = note(ctx, "untouched.md")

      assert :ok = run(ctx)
      assert path_of(ctx, n.id) == "untouched.md"
    end
  end

  # All three of these were reproduced empirically by an adversarial review
  # before they were fixed. A chain silently half-applied, a swap churned two
  # warnings forever, and a duplicated note_id oscillated a note twice per pass
  # minting tombstones and delete-broadcasts on every checkpoint.
  # Projection makes the index authoritative for paths. So every path the SERVER
  # changes must also land in the index, or the next projection run drags the
  # note back — tombstone at the new path, Qdrant repath, delete broadcast to
  # every device. These pin the dual-write that closes that (#1146 decision 4).
  describe "server-side changes are mirrored into the index" do
    test "a REST rename is NOT reverted by the next projection run", ctx do
      n = note(ctx, "Old/rest.md")
      seed_index(ctx, [{"Old/rest.md", n.id}])

      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Old/rest.md", "New/rest.md")

      assert :ok = run(ctx)

      assert path_of(ctx, n.id) == "New/rest.md",
             "projection dragged a server-side rename back to its old path"
    end

    # Identity has TWO paths: write through a live room, or rewrite the
    # persisted snapshot when there is none. Every other test here stops the
    # room before renaming, so they all exercise the snapshot path — and the
    # live-room branch could be deleted entirely with the suite still green.
    # It is also the branch that runs MOST in prod: a user renaming a note
    # while connected has a live index room.
    test "a rename with the index room LIVE is written through the room", ctx do
      n = note(ctx, "Old/live.md")

      # No on_exit unobserve: the test process IS the observer, so when it exits
      # the room's :DOWN fires auto_exit on its own. An on_exit callback runs in
      # a SEPARATE process after that, so it would call unobserve on a room that
      # has already gone — which exits the caller, the exact hazard
      # release_room/1 guards against (#1382).
      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      :ok =
        SharedDoc.update_doc(room, fn doc ->
          doc
          |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
          |> Yex.Map.set("Old/live.md", %{"note_id" => n.id})
        end)

      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Old/live.md", "New/live.md")

      # Read back out of the LIVE room, not the snapshot: that is what proves
      # the write took the room path rather than silently going to disk.
      assert read_live(room, "New/live.md")["note_id"] == n.id
      refute read_live(room, "Old/live.md")
    end

    # #1341. The snapshot path encrypts, and users.encrypted_dek holds the OLD
    # wrapped dek until final_flip — so a mid-rotation write lands a blob no
    # surviving key can read, on a row the sweep already re-wrapped.
    #
    # Under map-authority the claim IS the commit, so this cannot be
    # skipped-and-continued the way a derived side effect could: the rename
    # fails outright. Half-applying it — row moved, authority not updated — is
    # precisely the state projection would then REVERT.
    test "a rename during a DEK rotation fails instead of half-applying", ctx do
      n = note(ctx, "Old/rot.md")
      seed_index(ctx, [{"Old/rot.md", n.id}])

      before = tenant_index_ciphertext(ctx)

      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          set: [dek_rotation_locked_at: DateTime.utc_now()]
        )

      user = Repo.get!(Engram.Accounts.User, ctx.user.id)

      assert {:error, :rotation_in_progress} =
               Notes.rename_note(user, ctx.vault, "Old/rot.md", "New/rot.md")

      assert tenant_index_ciphertext(ctx) == before,
             "a refused claim must not touch the snapshot"

      assert path_of(ctx, n.id) == "Old/rot.md",
             "the row must not move when its claim was refused"
    end

    # The cascade used to claim AFTER its rows moved, which is the dual-write
    # ordering this design replaced. A refused claim then left N rows already
    # moved and projection reverted every one of them.
    test "a folder rename whose claim is refused moves no rows", ctx do
      a = note(ctx, "Src/a.md")
      squatter = note(ctx, "elsewhere.md")

      # The authority says Dst/a.md belongs to another note, while no ROW holds
      # it — so only the claim can catch this. A row-level check cannot.
      seed_index(ctx, [{"Src/a.md", a.id}, {"Dst/a.md", squatter.id}])

      assert {:error, :conflict} = Notes.rename_folder(ctx.user, ctx.vault, "Src", "Dst")

      assert path_of(ctx, a.id) == "Src/a.md",
             "the cascade moved rows even though its claim was refused"
    end

    # The batch used to claim per id INSIDE the loop, so a batch failing on a
    # later id had already committed the earlier ones in the authority: the rows
    # rolled back and the next projection run moved them anyway. The API
    # reported a failed batch that then happened regardless.
    test "a batch move that fails claims nothing", ctx do
      a = note(ctx, "a.md")
      seed_index(ctx, [{"a.md", a.id}])

      missing = Ecto.UUID.generate()

      assert {:error, {:not_found, ^missing}} =
               Notes.batch_move_notes(ctx.user, ctx.vault, [a.id, missing], {:path, "Dst"})

      assert path_of(ctx, a.id) == "a.md"

      refute Map.has_key?(index_entries(ctx), "Dst/a.md"),
             "a rolled-back batch left a claim behind, which projection would then apply"
    end

    test "a folder rename cascade is mirrored for every note it moved", ctx do
      a = note(ctx, "Src/a.md")
      b = note(ctx, "Src/b.md")

      seed_index(ctx, [{"Src/a.md", a.id}, {"Src/b.md", b.id}])

      {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "Src", "Dst")

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "Dst/a.md"
      assert path_of(ctx, b.id) == "Dst/b.md"
    end

    # A deleted note leaves its entry behind otherwise. Projection never
    # resurrects it — get_note_by_id is scoped_live — but the entry then warns
    # and counts as `unresolved` on every checkpoint forever, which is how a
    # real disagreement gets lost in noise.
    test "a deleted note's entry is dropped, so it stops counting as unresolved", ctx do
      attach_projection_telemetry()

      keep = note(ctx, "Old/keep.md")
      doomed = note(ctx, "doomed.md")

      seed_index(ctx, [{"doomed.md", doomed.id}, {"New/keep.md", keep.id}])

      :ok = Notes.delete_note(ctx.user, ctx.vault, "doomed.md")

      assert :ok = run(ctx)

      assert_receive {:projection, %{unresolved: 0}, %{phase: :converged}}, 2_000
      assert path_of(ctx, keep.id) == "New/keep.md"
    end
  end

  describe "entries that interact" do
    defp attach_projection_telemetry do
      test_pid = self()
      handler = "proj-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :index_projection],
        fn _e, m, meta, _ -> send(test_pid, {:projection, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    # a wants b's path; b is vacating it. Entry order is TERM order for small
    # maps, so "b.md" is visited before "c.md" — reliably the losing order. One
    # pass leaves `a` stranded; the fixpoint loop is what lands it.
    test "a chain converges in a single run", ctx do
      a = note(ctx, "a.md")
      b = note(ctx, "b.md")

      seed_index(ctx, [{"b.md", a.id}, {"c.md", b.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "b.md", "the chain must not be left half-applied"
      assert path_of(ctx, b.id) == "c.md"
    end

    # rename_note/4 has no temp-path staging, so a swap can never converge. The
    # loop must HALT on it and report, not churn.
    test "a swap halts and is reported as unresolved rather than churning", ctx do
      attach_projection_telemetry()

      a = note(ctx, "a.md")
      b = note(ctx, "b.md")

      seed_index(ctx, [{"b.md", a.id}, {"a.md", b.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "a.md"
      assert path_of(ctx, b.id) == "b.md"

      assert_receive {:projection, measurements, %{phase: :unresolved}}, 2_000
      assert measurements.applied == 0, "a swap makes no progress by construction"
      assert measurements.passes == 1, "zero progress must stop after ONE pass"
    end

    # Two paths claiming one note cannot both be satisfied. Applying them in
    # sequence moves the note twice per pass — tombstones, seq bumps, Qdrant
    # repaths and delete-broadcasts to every device, on every checkpoint.
    test "a note claimed by two paths is dropped, not oscillated", ctx do
      n = note(ctx, "orig.md")
      other = note(ctx, "Old/other.md")

      seed_index(ctx, [{"x.md", n.id}, {"y.md", n.id}, {"New/other.md", other.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, n.id) == "orig.md",
             "projection cannot pick a winner between two claims, so it moves nothing"

      assert path_of(ctx, other.id) == "New/other.md",
             "an unambiguous entry alongside them still applies"
    end

    test "a converged run reports converged", ctx do
      attach_projection_telemetry()

      n = note(ctx, "Old/fine.md")
      seed_index(ctx, [{"New/fine.md", n.id}])

      assert :ok = run(ctx)

      assert_receive {:projection, %{applied: 1, unresolved: 0}, %{phase: :converged}}, 2_000
    end

    # An empty index and "40 entries, all failed" used to be byte-identical to
    # logs, metrics, Oban and Sentry at once.
    test "an empty index is distinguishable from a failed one", ctx do
      attach_projection_telemetry()

      seed_index(ctx, [])
      assert :ok = run(ctx)

      assert_receive {:projection, %{applied: 0, unresolved: 0}, %{phase: :converged}}, 2_000
    end
  end

  describe "entries it cannot apply" do
    # `path_hmac` is UNIQUE per (user, vault). rename_note/4 pre-checks it and
    # answers {:error, :conflict} rather than crashing — projection must carry
    # that through instead of aborting the whole run.
    test "a collision is skipped and does not stop the rest of the batch", ctx do
      occupant = note(ctx, "taken.md")
      loser = note(ctx, "Old/loser.md")
      other = note(ctx, "Old/other.md")

      seed_index(ctx, [
        {"taken.md", loser.id},
        {"New/other.md", other.id}
      ])

      assert :ok = run(ctx)

      assert path_of(ctx, occupant.id) == "taken.md", "the occupant must not be displaced"
      assert path_of(ctx, loser.id) == "Old/loser.md", "the colliding entry is skipped"

      assert path_of(ctx, other.id) == "New/other.md",
             "one bad entry must not abort the entries after it"
    end

    test "an entry naming a note this vault does not have is skipped", ctx do
      real = note(ctx, "Old/real.md")

      seed_index(ctx, [
        {"ghost.md", Ecto.UUID.generate()},
        {"New/real.md", real.id}
      ])

      assert :ok = run(ctx)
      assert path_of(ctx, real.id) == "New/real.md"
    end

    test "a malformed entry is skipped rather than crashing the job", ctx do
      real = note(ctx, "Old/shape.md")

      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      :ok =
        SharedDoc.update_doc(room, fn doc ->
          map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
          Yex.Map.set(map, "junk.md", "not-a-map")
          Yex.Map.set(map, "New/shape.md", %{"note_id" => real.id})
        end)

      ref = Process.monitor(room)
      :ok = SharedDoc.unobserve(room)
      assert_receive {:DOWN, ^ref, :process, ^room, _}, 5_000

      assert :ok = run(ctx)
      assert path_of(ctx, real.id) == "New/shape.md"
    end
  end
end
