defmodule Engram.Indexing.ChunkDiffWriteTest do
  @moduledoc """
  A re-index rewrites only the chunk rows whose content or position changed
  (`Indexing.write_chunk_rows/2`), not every row. Counted from Postgres' own
  per-transaction table counters (`pg_stat_xact_user_tables`), so the test
  measures what was written, not what the code meant to write.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk

  setup :verify_on_exit!

  # Over 512 B a section, so each is its own chunk; 17 = the prod average
  # chunks per note (notes-chunks-hyperopt 1.6).
  @pad String.duplicate(" filler words here", 30)
  @sections 17

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

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp content(sections, fifth) do
    "# Plan\n\n" <>
      Enum.map_join(1..sections, "\n\n", fn i ->
        body = if i == 5, do: fifth, else: "Section #{i} stays."
        "## S#{i}\n\n#{body}#{@pad}"
      end) <> "\n"
  end

  defp put!(user, vault, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Dir/Plan.md", "content" => content},
        actor: "api"
      )

    {:ok, note} =
      note
      |> Repo.reload!(skip_tenant_check: true)
      |> Engram.Crypto.maybe_decrypt_note_fields(user)

    note
  end

  defp counters do
    %{rows: [[ins, upd, hot, del]]} =
      Repo.query!("""
      SELECT coalesce(sum(n_tup_ins), 0)::int, coalesce(sum(n_tup_upd), 0)::int,
             coalesce(sum(n_tup_hot_upd), 0)::int, coalesce(sum(n_tup_del), 0)::int
      FROM pg_stat_xact_user_tables WHERE relname = 'chunks'
      """)

    %{ins: ins, upd: upd, hot: hot, del: del}
  end

  defp index_count do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*)::int FROM pg_index WHERE indrelid = 'chunks'::regclass")

    n
  end

  # Rows written by `fun` and the index entries they cost: every insert and
  # every non-HOT update writes one entry per index.
  defp written(fun) do
    before = counters()
    fun.()
    a = counters()
    d = Map.new(a, fn {k, v} -> {k, v - before[k]} end)
    Map.put(d, :index_inserts, (d.ins + d.upd - d.hot) * index_count())
  end

  defp rows(note) do
    Repo.all(
      from(c in Chunk,
        where: c.note_id == ^note.id,
        order_by: c.position,
        select: {c.position, c.char_start, c.char_end, c.token_count, c.context_hmac}
      ),
      skip_tenant_check: true
    )
  end

  test "a one-chunk edit rewrites one row, not every row", ctx do
    note = put!(ctx.user, ctx.vault, content(@sections, "The fifth one is old."))

    first = written(fn -> assert {:ok, @sections} = Indexing.index_note(note, ctx.vault) end)
    assert first.ins == @sections

    # Same length, so no later section's offsets move.
    edited = put!(ctx.user, ctx.vault, content(@sections, "The fifth one is new."))
    second = written(fn -> assert {:ok, @sections} = Indexing.index_note(edited, ctx.vault) end)

    # Before: 17 deletes + 17 inserts = 17 x 5 indexes = 85 index entries.
    assert %{ins: 0, del: 0, upd: 1} = second
    assert second.index_inserts <= index_count()
  end

  test "an edit that shifts offsets only updates, and the rows match a fresh index", ctx do
    note = put!(ctx.user, ctx.vault, content(@sections, "Short."))
    {:ok, _} = Indexing.index_note(note, ctx.vault)

    edited = put!(ctx.user, ctx.vault, content(@sections, "A much longer fifth section now."))
    w = written(fn -> {:ok, _} = Indexing.index_note(edited, ctx.vault) end)
    assert w.ins == 0 and w.del == 0

    # Same user and path in another vault: identical fingerprints, so the
    # rows a wholesale write gives must equal the diffed ones.
    other = insert(:vault, user: ctx.user)
    fresh = put!(ctx.user, other, content(@sections, "A much longer fifth section now."))
    {:ok, _} = Indexing.index_note(fresh, other)
    assert rows(edited) == rows(fresh)
  end

  test "fewer and more chunks delete and insert only the difference", ctx do
    note = put!(ctx.user, ctx.vault, content(@sections, "Fifth."))
    {:ok, _} = Indexing.index_note(note, ctx.vault)

    shorter = put!(ctx.user, ctx.vault, content(@sections - 2, "Fifth."))
    w = written(fn -> {:ok, _} = Indexing.index_note(shorter, ctx.vault) end)
    assert %{ins: 0, del: 2} = w
    assert length(rows(shorter)) == @sections - 2

    longer = put!(ctx.user, ctx.vault, content(@sections, "Fifth."))
    w = written(fn -> {:ok, _} = Indexing.index_note(longer, ctx.vault) end)
    assert %{ins: 2, del: 0} = w
    assert length(rows(longer)) == @sections
  end

  # chunks.created_at had no reader: rows stop carrying it, and the column
  # is nullable so the contract release can drop it.
  test "chunk rows are written without created_at", ctx do
    note = put!(ctx.user, ctx.vault, content(3, "Fifth."))
    {:ok, _} = Indexing.index_note(note, ctx.vault)

    %{rows: [[set, nullable]]} =
      Repo.query!(
        """
        SELECT (SELECT count(*)::int FROM chunks WHERE note_id = $1 AND created_at IS NOT NULL),
               (SELECT is_nullable FROM information_schema.columns
                WHERE table_name = 'chunks' AND column_name = 'created_at')
        """,
        [Ecto.UUID.dump!(note.id)]
      )

    assert {set, nullable} == {0, "YES"}
  end
end
