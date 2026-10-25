defmodule Engram.Indexing.NoteCountsTest do
  @moduledoc """
  Per-note chunk counters on `note_index_state` (`points`, `len_rows`,
  `len_sum`) replace `count(*)` / `avg` over chunks for the point count and
  BM25 `avgdl`. Written by every chunk writer of this release in its own
  transaction under the note's lock; backfilled and healed by the
  `NoteIndexState` ledger. The counters must equal the chunks, checked in
  ONE statement, after every kind of write.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.DataMigrations
  alias Engram.DataMigrations.Entry
  alias Engram.DataMigrations.NoteIndexState, as: Ledger
  alias Engram.Indexing
  alias Engram.KeywordIndex.Stats
  alias Engram.Notes
  alias Engram.Notes.{Chunk, Note}

  setup :verify_on_exit!

  @pad String.duplicate(" filler words here", 30)

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    DataMigrations.reset_cache()
    Engram.Cache.clear_local(:avgdl)
    on_exit(&DataMigrations.reset_cache/0)
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp content(n, tag), do: Enum.map_join(1..n, "\n\n", &"## S#{&1}\n\n#{tag} #{&1}#{@pad}")

  defp index!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    {:ok, note} =
      note
      |> Repo.reload!(skip_tenant_check: true)
      |> Engram.Crypto.maybe_decrypt_note_fields(user)

    {:ok, _} = Indexing.index_note(note, vault)
    note
  end

  # ONE statement: notes whose counters differ from their chunk rows.
  defp drifted do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT count(*)::int FROM note_index_state s
      WHERE ROW(s.points, s.len_rows, s.len_sum) IS DISTINCT FROM (
        SELECT ROW(count(*)::int, count(c.token_count)::int, coalesce(sum(c.token_count), 0)::bigint)
        FROM chunks c WHERE c.note_id = s.note_id)
      """)

    n
  end

  defp counted! do
    Repo.insert!(
      %Entry{name: Ledger.name(), version: Ledger.version(), completed_at: DateTime.utc_now()},
      skip_tenant_check: true
    )

    DataMigrations.reset_cache()
  end

  defp chunks(user_id),
    do:
      Repo.aggregate(from(c in Chunk, where: c.user_id == ^user_id), :count,
        skip_tenant_check: true
      )

  test "every chunk writer keeps its note's counters exact", ctx do
    _a = index!(ctx.user, ctx.vault, "A.md", content(5, "alpha"))
    _b = index!(ctx.user, ctx.vault, "B.md", content(3, "bravo"))
    assert drifted() == 0

    # Re-indexes that edit, add and drop chunks (the diffed write).
    index!(ctx.user, ctx.vault, "A.md", content(7, "alphA"))
    assert drifted() == 0
    a = index!(ctx.user, ctx.vault, "A.md", content(2, "alpha"))
    assert drifted() == 0

    # The resparse rewrites lengths: start from rows with none, counted.
    Repo.query!("UPDATE chunks SET token_count = NULL WHERE note_id = $1", [
      Ecto.UUID.dump!(a.id)
    ])

    _ = Indexing.ChunkRows.recount!([a.id])
    assert drifted() == 0
    assert {:ok, n, _} = Indexing.resparse_note(a, ctx.user)
    assert n > 0

    assert Repo.one(
             from(c in Chunk,
               where: c.note_id == ^a.id and not is_nil(c.token_count),
               select: count()
             ),
             skip_tenant_check: true
           ) > 0

    assert drifted() == 0

    # The purge of a note's index.
    :ok = Indexing.delete_note_index(Repo.reload!(a, skip_tenant_check: true))
    assert drifted() == 0

    # The FK cascade takes the row with it.
    Repo.delete_all(from(n in Note, where: n.id == ^a.id), skip_tenant_check: true)
    assert drifted() == 0
  end

  # Old-release writers (a rolling deploy, a rollback) do not count: the
  # ledger finds the drift and heals it, so the one-statement check fails
  # until it does.
  test "the ledger heals counters a non-counting writer left behind", ctx do
    a = index!(ctx.user, ctx.vault, "A.md", content(5, "alpha"))
    b = index!(ctx.user, ctx.vault, "B.md", content(3, "bravo"))

    Repo.delete_all(from(c in Chunk, where: c.note_id == ^a.id and c.position > 1),
      skip_tenant_check: true
    )

    Repo.query!("UPDATE note_index_state SET points = 999 WHERE note_id = $1", [
      Ecto.UUID.dump!(b.id)
    ])

    assert drifted() == 2
    assert {:more, rows: 2} = Ledger.run_pass()
    assert drifted() == 0
    assert :done = Ledger.run_pass()
  end

  test "readers sum the counters once counted, and scan before", ctx do
    a = index!(ctx.user, ctx.vault, "A.md", content(4, "alpha"))
    real = chunks(ctx.user.id)
    assert Indexing.point_count(ctx.user.id) == real

    # A hand-edited counter proves which source each reader uses.
    Repo.query!(
      "UPDATE note_index_state SET points = points + 100, len_rows = 2, len_sum = 30 WHERE note_id = $1",
      [
        Ecto.UUID.dump!(a.id)
      ]
    )

    refute Ledger.counted?()
    assert Indexing.point_count(ctx.user.id) == real

    counted!()
    assert Ledger.counted?()
    assert Indexing.point_count(ctx.user.id) == real + 100
    # The budget sweep's cross-tenant form of the same query.
    assert {ctx.user.id, real + 100} in Repo.all(Indexing.points_by_user(),
             skip_tenant_check: true
           )

    Engram.Cache.clear_local(:avgdl)
    assert Stats.avgdl(ctx.user.id, ctx.vault.id) == 15.0
  end

  # Per note, so no shared row: another note's state row is not written.
  test "a chunk write touches only its own note's state row", ctx do
    b = index!(ctx.user, ctx.vault, "B.md", content(3, "bravo"))

    xmin = fn ->
      Repo.query!("SELECT xmin::text FROM note_index_state WHERE note_id = $1", [
        Ecto.UUID.dump!(b.id)
      ]).rows
    end

    before = xmin.()
    index!(ctx.user, ctx.vault, "A.md", content(3, "alpha"))
    assert xmin.() == before
  end
end
