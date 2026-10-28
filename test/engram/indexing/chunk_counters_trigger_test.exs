defmodule Engram.Indexing.ChunkCountersTriggerTest do
  @moduledoc """
  The `chunks_sync_note_counts_*` statement triggers keep each note's chunk
  counters on `note_index_state` (`points`, `len_rows`, `len_sum`) equal to
  its `chunks` rows on every write, whoever writes: this release, the
  previous one mid-deploy, raw SQL, an FK cascade. Every write here is raw
  (no `ChunkRows.recount!/2`), so only the trigger can keep them right.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Notes
  alias Engram.Notes.{Chunk, NoteIndexState}
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")

    note
  end

  defp row(note, pos, tokens) do
    %{
      note_id: note.id,
      user_id: note.user_id,
      vault_id: note.vault_id,
      position: pos,
      char_start: 0,
      char_end: 1,
      token_count: tokens,
      qdrant_point_id: Ecto.UUID.generate()
    }
  end

  defp insert!(rows), do: Repo.insert_all(Chunk, rows, skip_tenant_check: true)

  defp counters(note_id) do
    Repo.one!(
      from(s in NoteIndexState,
        where: s.note_id == ^note_id,
        select: {s.points, s.len_rows, s.len_sum}
      ),
      skip_tenant_check: true
    )
  end

  defp truth(note_id) do
    Repo.one!(
      from(c in Chunk,
        where: c.note_id == ^note_id,
        select:
          {type(count(c.note_id), :integer), type(count(c.token_count), :integer),
           type(coalesce(sum(c.token_count), 0), :integer)}
      ),
      skip_tenant_check: true
    )
  end

  defp assert_exact(note_id), do: assert(counters(note_id) == truth(note_id))

  # `note_index_state` rows updated so far in this transaction.
  defp state_updates do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT coalesce(sum(n_tup_upd), 0)::bigint FROM pg_stat_xact_user_tables " <>
          "WHERE relname = 'note_index_state'"
      )

    n
  end

  test "inserts, updates and deletes of any batch size keep the counters exact", %{
    user: u,
    vault: v
  } do
    note = note!(u, v, "a.md")
    assert counters(note.id) == {0, 0, 0}

    for {from, to} <- [{0, 0}, {1, 7}, {8, 57}] do
      insert!(for p <- from..to, do: row(note, p, rem(p, 3) * 10 + 1))
      assert_exact(note.id)
    end

    assert counters(note.id) == {58, 58, truth(note.id) |> elem(2)}

    # token_count to NULL, and to new values, in one statement each.
    Repo.update_all(
      from(c in Chunk, where: c.note_id == ^note.id and c.position < 10),
      [set: [token_count: nil]],
      skip_tenant_check: true
    )

    assert_exact(note.id)
    assert elem(counters(note.id), 1) == 48

    Repo.update_all(
      from(c in Chunk, where: c.note_id == ^note.id and c.position >= 50),
      [inc: [token_count: 5]],
      skip_tenant_check: true
    )

    assert_exact(note.id)

    Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id and c.position < 20),
      skip_tenant_check: true
    )

    assert_exact(note.id)

    Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)
    assert counters(note.id) == {0, 0, 0}
  end

  test "a chunk moved to another note recounts both", %{user: u, vault: v} do
    a = note!(u, v, "a.md")
    b = note!(u, v, "b.md")
    insert!(for p <- 0..9, do: row(a, p, 4))

    Repo.update_all(
      from(c in Chunk, where: c.note_id == ^a.id and c.position < 4),
      [set: [note_id: b.id]],
      skip_tenant_check: true
    )

    assert counters(a.id) == {6, 6, 24}
    assert counters(b.id) == {4, 4, 16}
  end

  test "one state write per note per statement, however many rows", %{user: u, vault: v} do
    note = note!(u, v, "a.md")
    before = state_updates()
    insert!(for p <- 0..49, do: row(note, p, 2))
    assert state_updates() - before == 1
    assert counters(note.id) == {50, 50, 100}
  end

  test "a bulk delete of 1,000 notes' chunks writes each note's state once", %{
    user: u,
    vault: v
  } do
    seed = note!(u, v, "seed.md")

    # 999 clones of the seed (the notes trigger gives each its state row),
    # then two chunks per note in ONE statement.
    Repo.query!(
      """
      INSERT INTO notes
      SELECT (r).* FROM (
        SELECT jsonb_populate_record(null::notes,
                 to_jsonb(n) || jsonb_build_object('id', gen_random_uuid(),
                                                   'path', 'gen/' || g || '.md',
                                                   'path_hmac', '\\\\x' || md5(g::text))) AS r
        FROM notes n, generate_series(1, 999) g WHERE n.id = $1) x
      """,
      [Ecto.UUID.dump!(seed.id)]
    )

    ids = Repo.all(from(n in "notes", select: n.id), skip_tenant_check: true)
    assert length(ids) == 1_000

    before = state_updates()

    Repo.query!("""
    INSERT INTO chunks (note_id, user_id, vault_id, position, char_start, char_end,
                        token_count, qdrant_point_id)
    SELECT n.id, n.user_id, n.vault_id, p, 0, 1, 3, gen_random_uuid()
    FROM notes n, generate_series(0, 1) p
    """)

    # Per statement, per note: 1,000, not 2,000.
    assert state_updates() - before == 1_000
    assert counters(seed.id) == {2, 2, 6}

    before = state_updates()
    Repo.query!("DELETE FROM chunks WHERE note_id = ANY($1)", [ids])
    assert state_updates() - before == 1_000

    assert Repo.aggregate(from(s in NoteIndexState, where: s.points != 0), :count,
             skip_tenant_check: true
           ) == 0
  end

  test "a note delete cascades through its chunks without error", %{user: u, vault: v} do
    note = note!(u, v, "a.md")
    insert!(for p <- 0..2, do: row(note, p, 1))
    Repo.query!("DELETE FROM notes WHERE id = $1", [Ecto.UUID.dump!(note.id)])
    assert Repo.get(NoteIndexState, note.id, skip_tenant_check: true) == nil
  end

  test "agrees with ChunkRows.recount!/2, the old absolute count", %{user: u, vault: v} do
    note = note!(u, v, "a.md")
    insert!(for p <- 0..11, do: row(note, p, p))
    after_trigger = counters(note.id)
    # Already exact: the old recount finds nothing to rewrite.
    assert Engram.Indexing.ChunkRows.recount!([note.id]) == 0
    assert counters(note.id) == after_trigger
  end

  describe "RLS" do
    test "control: the app role with no tenant cannot write chunks", %{user: u, vault: v} do
      note = note!(u, v, "a.md")

      assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               as_prod_role(fn -> insert!([row(note, 0, 1)]) end)
    end

    test "the trigger writes the counters under the app role inside the tenant", %{
      user: u,
      vault: v
    } do
      note = note!(u, v, "a.md")

      # Read back under the same role: a trigger write RLS filtered to zero
      # rows would leave the counters at zero.
      assert {:returned, {:ok, {3, 3, 21}}} =
               as_prod_role(fn ->
                 Repo.with_tenant(u.id, fn ->
                   insert!(for p <- 0..2, do: row(note, p, 7))
                   counters(note.id)
                 end)
               end)
    end
  end
end
