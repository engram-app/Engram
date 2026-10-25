defmodule Engram.Indexing.ChunkStatsTest do
  @moduledoc """
  `chunk_stats` (per-vault point and length counters, kept by statement
  triggers on `chunks`) replaces `count(*)` / `avg` over chunks for the
  point count and BM25 `avgdl`. The counters must equal the aggregate after
  every kind of chunk write, checked in ONE statement.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase
  import Mox

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

    Engram.Cache.clear_local(:avgdl)
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user, vault: insert(:vault, user: user), other: insert(:vault, user: user)}
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

  # ONE statement: every vault whose counters differ from its chunks. A
  # vault with no row yet is not a mismatch (readers fall back to a scan).
  defp mismatches do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT count(*)::int FROM chunk_stats s
      FULL JOIN (SELECT vault_id, count(*) AS points, count(token_count) AS len_rows,
                        coalesce(sum(token_count), 0) AS len_sum
                 FROM chunks GROUP BY vault_id) a USING (vault_id)
      WHERE s.vault_id IS NOT NULL
        AND (s.points, s.len_rows, s.len_sum) IS DISTINCT FROM
            (coalesce(a.points, 0), coalesce(a.len_rows, 0), coalesce(a.len_sum, 0))
      """)

    n
  end

  defp stats_rows, do: Repo.query!("SELECT vault_id FROM chunk_stats").num_rows

  test "the counters follow every kind of chunk write", ctx do
    a = index!(ctx.user, ctx.vault, "A.md", content(5, "alpha"))
    _b = index!(ctx.user, ctx.other, "B.md", content(3, "bravo"))
    assert stats_rows() == 2
    assert mismatches() == 0

    # A re-index that edits, adds and drops chunks.
    index!(ctx.user, ctx.vault, "A.md", content(7, "alphA"))
    assert mismatches() == 0
    index!(ctx.user, ctx.vault, "A.md", content(2, "alpha"))
    assert mismatches() == 0

    # A token_count rewrite (resparse) and a NULL-ing (floor/merged rows).
    Repo.update_all(from(c in Chunk, where: c.note_id == ^a.id), [inc: [token_count: 3]],
      skip_tenant_check: true
    )

    assert mismatches() == 0

    Repo.update_all(from(c in Chunk, where: c.note_id == ^a.id), [set: [token_count: nil]],
      skip_tenant_check: true
    )

    assert mismatches() == 0

    # The FK cascade from a note delete.
    Repo.delete_all(from(n in Note, where: n.id == ^a.id), skip_tenant_check: true)
    assert mismatches() == 0

    # A vault delete takes its row with it.
    Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.id == ^ctx.other.id),
      skip_tenant_check: true
    )

    assert stats_rows() == 1
    assert mismatches() == 0
  end

  test "a vault's first write counts what it already held", ctx do
    index!(ctx.user, ctx.vault, "A.md", content(4, "alpha"))
    Repo.query!("DELETE FROM chunk_stats")

    # Rows written before the trigger: the next insert counts them all.
    index!(ctx.user, ctx.vault, "B.md", content(2, "bravo"))
    assert stats_rows() == 1
    assert mismatches() == 0
  end

  test "point_count and avgdl read the counters, and scan a vault with none", ctx do
    index!(ctx.user, ctx.vault, "A.md", content(4, "alpha"))
    index!(ctx.user, ctx.other, "B.md", content(2, "bravo"))

    real =
      Repo.aggregate(from(c in Chunk, where: c.user_id == ^ctx.user.id), :count,
        skip_tenant_check: true
      )

    assert Indexing.point_count(ctx.user.id) == real

    # Prove the source: a counter edited by hand is what the readers return.
    Repo.query!(
      "UPDATE chunk_stats SET points = points + 100, len_rows = 2, len_sum = 30 WHERE vault_id = $1",
      [
        Ecto.UUID.dump!(ctx.vault.id)
      ]
    )

    assert Indexing.point_count(ctx.user.id) == real + 100
    Engram.Cache.clear_local(:avgdl)
    assert Stats.avgdl(ctx.user.id, ctx.vault.id) == 15.0

    # No row: the scan, as before.
    Repo.query!("DELETE FROM chunk_stats")
    Engram.Cache.clear_local(:avgdl)
    assert Indexing.point_count(ctx.user.id) == real
    assert Stats.avgdl(ctx.user.id, ctx.vault.id) > 0
  end

  describe "RLS" do
    test "control: the dropped role with no tenant sees zero rows", ctx do
      index!(ctx.user, ctx.vault, "A.md", content(2, "alpha"))
      assert stats_rows() > 0

      assert {:returned, %{num_rows: 0}} =
               as_prod_role(fn -> Repo.query!("SELECT 1 FROM chunk_stats") end)
    end

    test "another tenant's counters are invisible", ctx do
      index!(ctx.user, ctx.vault, "A.md", content(2, "alpha"))
      stranger = insert(:user)

      assert {:returned, {:ok, %{num_rows: 0}}} =
               as_prod_role(fn ->
                 Repo.with_tenant(stranger.id, fn -> Repo.query!("SELECT 1 FROM chunk_stats") end)
               end)

      assert {:returned, {:ok, %{num_rows: 1}}} =
               as_prod_role(fn ->
                 Repo.with_tenant(ctx.user.id, fn -> Repo.query!("SELECT 1 FROM chunk_stats") end)
               end)
    end
  end
end
