defmodule Engram.Indexing.VectorCacheTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.UserDekRotation
  alias Engram.Indexing.VectorCache
  alias Engram.Repo

  @opts [model: "voyage-4-large", dims: 1024, dtype: "float", input_type: "document"]
  @ck :crypto.strong_rand_bytes(32)

  # A vector every value of which f16 holds exactly, packed as the embed path
  # hands it over (f32 LE).
  defp vector(seed, dims \\ 1024) do
    for i <- 1..dims, into: <<>>, do: <<rem(i * seed, 2048) / 2048 - 0.5::float-32-little>>
  end

  defp user_and_dek do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, dek} = Crypto.get_dek(user)
    {user, dek}
  end

  defp put(user, dek, text, vec, ck \\ @ck) do
    digest = VectorCache.digest(text, @opts)
    key = VectorCache.key_for_digest(ck, digest)
    :ok = VectorCache.put_many(user.id, nil, dek, [{key, digest, vec}])
    key
  end

  defp rows(user_id) do
    Repo.query!("SELECT key, vector_ciphertext FROM embedding_cache WHERE user_id = $1", [
      Ecto.UUID.dump!(user_id)
    ]).rows
  end

  describe "key/3 (H11)" do
    test "model, dims, dtype and input type each change the key" do
      base = VectorCache.key(@ck, "some text", @opts)

      for {k, v} <- [model: "voyage-4-lite", dims: 512, dtype: "int8", input_type: "query"] do
        refute VectorCache.key(@ck, "some text", Keyword.put(@opts, k, v)) == base, "#{k}"
      end
    end

    test "NFD and NFC of the same text, and a zero-width space, give the same key" do
      nfc = "café password"
      nfd = "café password"
      assert VectorCache.key(@ck, nfc, @opts) == VectorCache.key(@ck, nfd, @opts)

      assert VectorCache.key(@ck, "pass​word", @opts) ==
               VectorCache.key(@ck, "password", @opts)
    end

    test "iodata and binary of the same text give the same key" do
      assert VectorCache.key(@ck, ["ab", ["c"]], @opts) == VectorCache.key(@ck, "abc", @opts)
    end

    test "is keyed: another subkey gives another key for the same text" do
      refute VectorCache.key(@ck, "t", @opts) ==
               VectorCache.key(:crypto.strong_rand_bytes(32), "t", @opts)
    end
  end

  describe "put_many/4 and get_many/3 (H13)" do
    test "an f16 vector round-trips exactly, and the stored column is not the vector" do
      {user, dek} = user_and_dek()
      vec = vector(7)
      key = put(user, dek, "hello", vec)

      assert %{^key => ^vec} = VectorCache.get_many(user.id, dek, [key])

      [[^key, ct]] = rows(user.id)
      f16 = VectorCache.f32_to_f16(vec)
      assert :binary.match(ct, f16) == :nomatch
      assert :binary.match(ct, binary_part(f16, 0, 64)) == :nomatch
    end

    test "a second user with the same text gets another key and no hit" do
      {a, dek_a} = user_and_dek()
      {b, dek_b} = user_and_dek()
      {:ok, ck_a} = Crypto.dek_content_hash_key(a)
      {:ok, ck_b} = Crypto.dek_content_hash_key(b)

      key_a = put(a, dek_a, "shared prose", vector(3), ck_a)
      key_b = VectorCache.key(ck_b, "shared prose", @opts)

      refute key_a == key_b
      assert VectorCache.get_many(b.id, dek_b, [key_b]) == %{}
      # Even handed A's key, B's lookup is scoped to B's rows.
      assert VectorCache.get_many(b.id, dek_b, [key_a]) == %{}
    end

    test "a row under another DEK is a miss, and the next put overwrites it" do
      {user, dek} = user_and_dek()
      key = put(user, :crypto.strong_rand_bytes(32), "x", vector(5))

      assert VectorCache.get_many(user.id, dek, [key]) == %{}

      key = put(user, dek, "x", vector(5))
      assert %{^key => _} = VectorCache.get_many(user.id, dek, [key])
    end

    test "a 10 MiB note's worth of vectors (6,000) writes and reads back in one lookup" do
      {user, dek} = user_and_dek()
      vec = vector(11)

      entries =
        for i <- 1..6_000 do
          digest = VectorCache.digest("chunk #{i}", @opts)
          {VectorCache.key_for_digest(@ck, digest), digest, vec}
        end

      :ok = VectorCache.put_many(user.id, nil, dek, entries)
      keys = Enum.map(entries, &elem(&1, 0))

      {:ok, hits} = count_queries(fn -> VectorCache.get_many(user.id, dek, keys) end)
      assert map_size(hits) == 6_000
    end

    test "emits hit and miss counts" do
      {user, dek} = user_and_dek()
      key = put(user, dek, "a", vector(2))
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :vector_cache, :lookup]])

      VectorCache.get_many(user.id, dek, [key, :crypto.strong_rand_bytes(32)])

      assert_receive {[:engram, :vector_cache, :lookup], ^ref, %{hits: 1, misses: 1}, _}
    end
  end

  describe "retention" do
    test "rows of a deleted user and of a hard-deleted note go with them" do
      {user, dek} = user_and_dek()
      vault = insert(:vault, user: user)
      note = insert(:note, user: user, vault: vault)
      digest = VectorCache.digest("n", @opts)
      key = VectorCache.key_for_digest(@ck, digest)
      :ok = VectorCache.put_many(user.id, note.id, dek, [{key, digest, vector(1)}])
      put(user, dek, "kept until the user goes", vector(1))
      assert length(rows(user.id)) == 2

      Repo.query!("DELETE FROM notes WHERE id = $1", [Ecto.UUID.dump!(note.id)])
      assert [[other, _]] = rows(user.id)
      refute other == key

      Repo.query!("DELETE FROM vaults WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])
      Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
      assert rows(user.id) == []
    end

    test "prune drops rows unused for 30 days and bounds each user to the newest rows" do
      {user, dek} = user_and_dek()
      stale = put(user, dek, "stale", vector(1))
      old = put(user, dek, "old", vector(1))
      new = put(user, dek, "new", vector(1))

      age = fn key, days ->
        Repo.query!(
          "UPDATE embedding_cache SET last_used_at = now() - make_interval(days => $2) WHERE key = $1",
          [key, days]
        )
      end

      age.(stale, 31)
      age.(old, 2)

      Application.put_env(:engram, :vector_cache_max_rows_per_user, 1)
      on_exit(fn -> Application.delete_env(:engram, :vector_cache_max_rows_per_user) end)

      assert VectorCache.prune(Repo) == 2
      assert [[^new, _]] = rows(user.id)
    end
  end

  describe "DEK rotation" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":{"points":[],"next_page_offset":null}}))
      end)

      :ok
    end

    test "re-keys every row under the new DEK: the same text still hits, no Voyage call" do
      Mox.stub(Engram.MockEmbedder, :embed_texts, fn _ -> flunk("rotation called Voyage") end)
      {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
      {:ok, dek} = Crypto.get_dek(user)
      {:ok, ck} = Crypto.dek_content_hash_key(user)
      vec = vector(9)
      old_key = put(user, dek, "rotate me", vec, ck)

      assert :ok = UserDekRotation.rotate_user(user.id)

      user = Repo.reload!(user, skip_tenant_check: true)
      {:ok, new_dek} = Crypto.get_dek(user)
      {:ok, new_ck} = Crypto.dek_content_hash_key(user)
      refute new_dek == dek
      new_key = VectorCache.key(new_ck, "rotate me", @opts)

      assert %{^new_key => ^vec} = VectorCache.get_many(user.id, new_dek, [new_key])
      assert [[^new_key, _]] = rows(user.id)
      refute new_key == old_key
    end

    test "rotate/3 is resumable: a second run keeps the re-keyed rows" do
      {user, dek} = user_and_dek()
      new_dek = :crypto.strong_rand_bytes(32)
      new_ck = Crypto.dek_content_hash_key_from_bytes(new_dek)
      put(user, dek, "twice", vector(4))

      :ok = VectorCache.rotate(user.id, dek, new_dek)
      :ok = VectorCache.rotate(user.id, dek, new_dek)

      key = VectorCache.key(new_ck, "twice", @opts)
      assert %{^key => _} = VectorCache.get_many(user.id, new_dek, [key])
      assert length(rows(user.id)) == 1
    end
  end

  defp count_queries(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      inspect(ref),
      [:engram, :repo, :query],
      fn _, _, %{query: q}, _ -> if q =~ "embedding_cache", do: send(parent, {ref, :q}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(inspect(ref))
    count = drain(ref, 0)
    assert count == 1, "expected ONE embedding_cache query, got #{count}"
    {:ok, result}
  end

  defp drain(ref, n) do
    receive do
      {^ref, :q} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
