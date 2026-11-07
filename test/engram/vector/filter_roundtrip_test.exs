defmodule Engram.Vector.FilterRoundtripTest do
  @moduledoc """
  Against a real Qdrant with strict mode ON (`unindexed_filtering_retrieve:
  false`), on the collection `ensure_collection/2` builds:

    * the R3a note scope: `n any [ids]`, `is_empty(n)` and `must_not n any`
      are accepted (no 400); a point without `n` passes the scope (for
      `Engram.Search` to post-filter), legacy-format points still match their
      tenant, and tenants never cross;
    * release D's per-note filters (`delete_by_note*`, `count_by_note`): a
      point with `n` by its note id, one without `n` by its path.
  """
  use ExUnit.Case, async: false

  alias Engram.Indexing
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  @moduletag :qdrant_integration

  @dims 8
  @vector List.duplicate(0.1, @dims)

  setup_all do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())

    col =
      "engram_rt_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}_" <>
        Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    :ok = Qdrant.ensure_collection(col, @dims)

    {:ok, %{status: 200}} =
      Req.patch("#{qdrant_url()}/collections/#{col}",
        json: %{strict_mode_config: %{enabled: true, unindexed_filtering_retrieve: false}}
      )

    Engram.QdrantIntegration.drop_on_exit(col)

    %{col: col}
  end

  setup do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())
    # The per-note filters' `n` arm (`config/test.exs` turns its probe off
    # for the Bypass suites). Every per-note call here goes through it.
    ServiceConfig.put_override(:qdrant_note_id_filter, true)
    Engram.Cache.clear_local(:note_id_filter)
    on_exit(fn -> Engram.Cache.clear_local(:note_id_filter) end)
    :ok
  end

  defp tenant,
    do: %{
      user_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      path: :crypto.strong_rand_bytes(32)
    }

  defp point(payload),
    do: %{id: Ecto.UUID.generate(), vector: %{"dense" => @vector}, payload: payload}

  defp identity(t, note_id), do: Indexing.identity_payload(Map.put(t, :id, note_id))

  # What an R3a pass writes: the identity, no path key.
  defp v5_point(t, note_id), do: point(identity(t, note_id))

  # A v5 point written before `n` (R2): tenant keys and its path.
  defp pre_n_point(t) do
    %{"u" => u, "v" => v} = identity(t, Ecto.UUID.generate())
    point(%{"u" => u, "v" => v, "p" => FilterId.from_hmac(t.path)})
  end

  # A v5 point written between R2 and R3a: `n` and its path.
  defp n_path_point(t, note_id),
    do: point(Map.put(identity(t, note_id), "p", FilterId.from_hmac(t.path)))

  # A v3 writer's point: long keys only.
  defp v3_point(t),
    do:
      point(%{user_id: t.user_id, vault_id: t.vault_id, path_hmac: Base.encode64(t.path)})

  defp ids(col, opts) do
    {:ok, hits} = Qdrant.search(col, @vector, [limit: 10] ++ opts)
    hits |> Enum.map(& &1.qdrant_id) |> Enum.sort()
  end

  defp left(col, t), do: ids(col, user_id: t.user_id, vault_id: t.vault_id)

  describe "the note scope (R3a)" do
    test "ids: n any for points with n, is_empty(n) lets the rest through", %{col: col} do
      t = tenant()
      [hit, miss] = for _ <- 1..2, do: Ecto.UUID.generate()
      a = v5_point(t, hit)
      b = v5_point(t, miss)
      c = pre_n_point(t)
      d = v3_point(t)
      :ok = Qdrant.upsert_points(col, [a, b, c, d])
      base = [user_id: t.user_id, vault_id: t.vault_id]

      assert ids(col, base ++ [note_scope: {:ids, [hit]}]) == Enum.sort([a.id, c.id, d.id])
    end

    test "exclude: must_not n any keeps every other point", %{col: col} do
      t = tenant()
      [kept, gone] = for _ <- 1..2, do: Ecto.UUID.generate()
      a = v5_point(t, kept)
      b = v5_point(t, gone)
      c = v3_point(t)
      :ok = Qdrant.upsert_points(col, [a, b, c])
      base = [user_id: t.user_id, vault_id: t.vault_id]

      assert ids(col, base ++ [note_scope: {:exclude, [gone]}]) == Enum.sort([a.id, c.id])
    end

    test "tenants never cross, whatever the scope", %{col: col} do
      [t1, t2] = [tenant(), tenant()]
      note = Ecto.UUID.generate()
      mine = v5_point(t1, note)
      theirs = v5_point(t2, note)
      other_legacy = v3_point(t2)
      :ok = Qdrant.upsert_points(col, [mine, theirs, other_legacy])

      for scope <- [{:ids, [note]}, {:exclude, []}, {:exclude, [Ecto.UUID.generate()]}] do
        assert ids(col, user_id: t1.user_id, vault_id: t1.vault_id, note_scope: scope) == [
                 mine.id
               ]
      end
    end
  end

  describe "the per-note filters (release D)" do
    test "a note's points match by n, and by path only without n", %{col: col} do
      t = tenant()
      id = Ecto.UUID.generate()
      [v3, v5, r3a] = [v3_point(t), n_path_point(t, id), v5_point(t, id)]
      :ok = Qdrant.upsert_points(col, [v3, v5, r3a])
      path = Base.encode64(t.path)

      assert {:ok, 3} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)

      assert :ok = Qdrant.delete_by_note_except(col, t.user_id, t.vault_id, id, path, [r3a.id])
      assert left(col, t) == [r3a.id]

      assert :ok = Qdrant.delete_by_note_except(col, t.user_id, t.vault_id, id, path, [v5.id])
      assert left(col, t) == []

      :ok = Qdrant.upsert_points(col, [r3a])
      assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, id, path)
      assert {:ok, 0} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
    end

    # Rename swap: note A left path X, note B moved onto X. A's old-path
    # delete must not reach B's points. A point with `n` is matched by `n`
    # only; a point with no `n` can only be matched by path (as before).
    test "a note's old path never reaches another note's points that carry n", %{col: col} do
      t = tenant()
      [a, b] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      b_point = n_path_point(t, b)
      no_n = pre_n_point(t)
      :ok = Qdrant.upsert_points(col, [b_point, no_n, v5_point(t, a)])
      path = Base.encode64(t.path)

      assert {:ok, 2} = Qdrant.count_by_note(col, t.user_id, t.vault_id, a, path)
      assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, a, path)
      assert left(col, t) == [b_point.id]
    end

    # Strict mode 400s a filter on `n` while the collection has no `n` index:
    # the per-note filters fall back to the path alone. `ensure_collection/2`
    # rebuilding the index replaces the cached "no", so the very next filter
    # takes the `n` arm (no stale-"no" minute after boot).
    test "without the n index: path alone, no 400; ensure_collection turns the n arm on",
         %{col: col} do
      {:ok, %{status: 200}} = Req.delete("#{qdrant_url()}/collections/#{col}/index/n?wait=true")
      # Restore the index even if an assertion below fails (`on_exit` runs in
      # another process, so it needs the URL override again).
      url = qdrant_url()

      on_exit(fn ->
        ServiceConfig.put_override(:qdrant_url, url)
        Application.put_env(:engram, :ensure_collection_memo, false)
        Qdrant.forget_collection_memo()
        Qdrant.ensure_collection(col, @dims)
      end)

      # `ensure_collection/2` marks the index only where its memo runs.
      Application.put_env(:engram, :ensure_collection_memo, true)

      refute Qdrant.n_filterable?(col)
      assert Qdrant.n_index(col) == :missing

      t = tenant()
      id = Ecto.UUID.generate()
      r3a = v5_point(t, id)
      :ok = Qdrant.upsert_points(col, [n_path_point(t, id), r3a])
      path = Base.encode64(t.path)

      assert {:ok, 1} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
      assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, id, path)
      assert left(col, t) == [r3a.id]

      assert :ok = Qdrant.ensure_collection(col, @dims)
      assert Qdrant.n_index(col) == :present
      assert {:ok, 1} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
      assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, id, path)
      assert left(col, t) == []
    end
  end

  defp qdrant_url do
    System.get_env("QDRANT_URL") ||
      Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
  end
end
