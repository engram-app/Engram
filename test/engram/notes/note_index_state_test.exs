defmodule Engram.Notes.NoteIndexStateTest do
  # The notes_sync_index_state trigger keeps note_index_state in step with
  # every write of an embed bookkeeping column, and the NoteIndexState data
  # migration fills rows written before it.
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.DataMigrations.NoteIndexState, as: Backfill
  alias Engram.Notes
  alias Engram.Notes.{Note, NoteIndexState}
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp write!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp state(id), do: Repo.get(NoteIndexState, id, skip_tenant_check: true)
  defp note(id), do: Repo.get!(Note, id, skip_tenant_check: true)

  defp xmin(id) do
    %{rows: [[x]]} =
      Repo.query!("SELECT xmin::text FROM note_index_state WHERE note_id = $1", [
        Ecto.UUID.dump!(id)
      ])

    x
  end

  defp mirrors?(state, note),
    do: Map.take(state, NoteIndexState.mirrored()) == Map.take(note, NoteIndexState.mirrored())

  defp stamp!(id, set),
    do: Repo.update_all(from(n in Note, where: n.id == ^id), [set: set], skip_tenant_check: true)

  test "a note insert writes its state row", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    assert %NoteIndexState{user_id: user_id} = s = state(n.id)
    assert user_id == u.id
    assert mirrors?(s, note(n.id))
  end

  test "every embed stamp reaches the state row", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    at = ~U[2026-10-24 12:00:00.000000Z]

    stamp!(n.id,
      embed_hash: n.content_hash,
      dense_indexed_hash: n.content_hash,
      chunker_version: 5,
      keyword_version: 4,
      key_alias_version: 2,
      embed_model: "voyage-4-large",
      payload_hash: <<1, 2, 3>>,
      index_tier: "floor",
      chunk_count: 7,
      rebuild_paid_at: at,
      embed_retry_after: at,
      embed_budget_parked: true,
      embed_budget_parked_at: at,
      embed_budget_need: 1_234,
      embed_budget_next: 56,
      embed_started_at: at,
      embed_started_by: "node@x",
      embed_started_hash: n.content_hash,
      embed_crashes: 2
    )

    s = state(n.id)
    assert s.chunker_version == 5 and s.embed_budget_need == 1_234 and s.index_tier == "floor"
    assert mirrors?(s, note(n.id))

    # And a NULL-clear (DEK rotation, cluster diff, payload drift).
    stamp!(n.id, keyword_version: nil, payload_hash: nil)
    assert %{keyword_version: nil, payload_hash: nil} = state(n.id)
  end

  test "a write that lists no mirrored column leaves the state row alone", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    before = xmin(n.id)

    stamp!(n.id, mtime: 42.0)
    assert xmin(n.id) == before

    # Listed but unchanged: the upsert skips an identical row.
    stamp!(n.id, embed_hash: note(n.id).embed_hash)
    assert xmin(n.id) == before
  end

  test "a folder marker gets no state row", %{user: u, vault: v} do
    {:ok, folder} = Notes.create_folder_marker(u, v, "Dir")
    assert state(folder.id) == nil
  end

  test "the row goes with its note", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    Repo.delete_all(from(x in Note, where: x.id == ^n.id), skip_tenant_check: true)
    assert state(n.id) == nil
  end

  describe "NoteIndexState backfill" do
    test "fills rows written before the trigger, then reports done", %{user: u, vault: v} do
      a = write!(u, v, "A.md", "# A\n\nbody")
      b = write!(u, v, "B.md", "# B\n\nbody")
      stamp!(a.id, chunker_version: 3, embed_budget_need: 9)
      Repo.query!("DELETE FROM note_index_state")

      assert {:more, rows: 2} = Backfill.run_pass()
      assert mirrors?(state(a.id), note(a.id))
      assert state(a.id).chunker_version == 3
      assert mirrors?(state(b.id), note(b.id))
      assert :done = Backfill.run_pass()
    end

    test "never replaces a row the trigger wrote", %{user: u, vault: v} do
      a = write!(u, v, "A.md", "# A\n\nbody")
      Repo.query!("UPDATE note_index_state SET keyword_version = 99")

      assert :done = Backfill.run_pass()
      assert state(a.id).keyword_version == 99
    end

    test "keyset-pages across batches", %{user: u, vault: v} do
      for i <- 1..3, do: write!(u, v, "N#{i}.md", "# N\n\nbody #{i}")
      Repo.query!("DELETE FROM note_index_state")

      assert {:more, rows: 3} = Backfill.run_pass(batch: 2)
      assert :done = Backfill.run_pass(batch: 2)
    end
  end

  describe "RLS" do
    test "control: the dropped role with no tenant sees zero rows", %{user: u, vault: v} do
      write!(u, v, "A.md", "# A\n\nbody")
      assert Repo.aggregate(NoteIndexState, :count, skip_tenant_check: true) > 0

      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.aggregate(NoteIndexState, :count, skip_tenant_check: true)
               end)
    end

    test "a tenant sees only its own rows", %{user: u, vault: v} do
      mine = write!(u, v, "A.md", "# A\n\nbody")
      other = insert(:user)
      {:ok, other} = Engram.Crypto.ensure_user_dek(other)
      write!(other, insert(:vault, user: other), "B.md", "# B\n\nbody")

      assert {:returned, {:ok, [id]}} =
               as_prod_role(fn ->
                 Repo.with_tenant(u.id, fn ->
                   Repo.all(from(s in NoteIndexState, select: s.note_id))
                 end)
               end)

      assert id == mine.id
    end

    test "the trigger writes under the app role inside the tenant", %{user: u, vault: v} do
      n = write!(u, v, "A.md", "# A\n\nbody")

      assert {:returned, {:ok, {1, nil}}} =
               as_prod_role(fn ->
                 Repo.with_tenant(u.id, fn ->
                   Repo.update_all(from(x in Note, where: x.id == ^n.id),
                     set: [chunker_version: 4]
                   )
                 end)
               end)
    end
  end
end
