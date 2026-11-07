defmodule Engram.DataMigrations.NoteFolderHashNullTest do
  # R9 release E null batch: clears `notes.folder_hmac` on notes whose live
  # folder row holds the same hash, keeps roots, markers, drift and
  # disagreeing rows, refuses to run while `note_payload_stamps` is open, and
  # honours its kill switch and per-pass cap.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteFolderHashNull, as: Null
  alias Engram.DataMigrations.NotePayloadStamps, as: Stamps
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Workers.DataMigrationsRunner

  setup do
    IdWindows.reset_walk(Null.name())
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  # Written while the ledger is open: every note carries its hash, as every
  # row written before release E does.
  defp note!(u, v, path) do
    {:ok, n} =
      Notes.upsert_note(u, v, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    n
  end

  defp hash_at(id) do
    %{rows: [[h]]} = Repo.query!("SELECT folder_hmac FROM notes WHERE id = $1", [dump(id)])
    h
  end

  defp done!, do: :ok = DataMigrations.mark_done(Stamps.name(), Stamps.version())

  defp run_to_done(opts \\ []) do
    Enum.reduce_while(1..20, nil, fn _, _ ->
      case Null.run_pass(opts) do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  test "is registered after FolderTable" do
    migrations = DataMigrationsRunner.migrations()

    assert Enum.find_index(migrations, &(&1 == Null)) ==
             Enum.find_index(migrations, &(&1 == DataMigrations.FolderTable)) + 1
  end

  test "blocked while note_payload_stamps is open: nothing is nulled", %{user: u, vault: v} do
    n = note!(u, v, "A/n.md")
    assert Null.run_pass() == {:more, rows: 0, blocked: 1}
    assert is_binary(hash_at(n.id))
  end

  test "nulls placed notes, keeps roots, markers, drift and disagreeing rows", %{
    user: u,
    vault: v
  } do
    placed = note!(u, v, "A/n.md")
    nested = note!(u, v, "A/B/m.md")
    root = note!(u, v, "top.md")
    drift = note!(u, v, "D/d.md")
    other = note!(u, v, "E/e.md")
    {:ok, marker} = Notes.create_folder_marker(u, v, "M")

    Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(drift.id)])
    # A row whose hash and folder row disagree (a reference to another folder).
    Repo.query!(
      "UPDATE notes SET folder_ref_id = (SELECT folder_ref_id FROM notes WHERE id = $2) WHERE id = $1",
      [dump(other.id), dump(placed.id)]
    )

    refs_before = Repo.query!("SELECT id, folder_ref_id FROM notes ORDER BY id").rows
    done!()
    assert run_to_done() == :done

    assert hash_at(placed.id) == nil
    assert hash_at(nested.id) == nil
    for kept <- [root, drift, other, marker], do: assert(is_binary(hash_at(kept.id)))
    assert Repo.query!("SELECT id, folder_ref_id FROM notes ORDER BY id").rows == refs_before
  end

  test "rerun-safe: a hash a release-C node writes back is nulled by a new pass", %{
    user: u,
    vault: v
  } do
    n = note!(u, v, "A/n.md")
    hash = hash_at(n.id)
    done!()
    assert run_to_done() == :done

    Repo.query!("UPDATE notes SET folder_hmac = $2 WHERE id = $1", [dump(n.id), hash])
    IdWindows.reset_walk(Null.name())
    assert run_to_done() == :done
    assert hash_at(n.id) == nil
  end

  test "the per-pass cap: one row per pass with max_fixed: 1, windows of 1", %{user: u, vault: v} do
    notes = for i <- 1..3, do: note!(u, v, "A/n#{i}.md")
    done!()

    assert {:more, _} = Null.run_pass(max_fixed: 1, batch: 1)
    assert Enum.count(notes, &(hash_at(&1.id) == nil)) == 1
  end

  test "the cap and the kill switch are service overrides" do
    assert Null.max_fixed() == 2_000
    ServiceConfig.put_override(:note_folder_hash_null_max_fixed, 5)
    assert Null.max_fixed() == 5

    assert Null.enabled?()
    ServiceConfig.put_override(:note_folder_hash_null, false)
    refute Null.enabled?()
  end
end
