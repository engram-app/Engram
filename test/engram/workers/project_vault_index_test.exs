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

  alias Engram.{Crypto, Notes, Vaults}
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
