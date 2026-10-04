defmodule Engram.IndexingMemoryTest do
  # Prod worker OOM, 2026-10-03: indexing a 2.7 MB note peaked ~485 MB above
  # baseline even after the link-regex fix. Every chunk's 1024-dim vector was
  # held as an Elixir float list (~32 bytes per float on the heap) for the whole
  # note until commit. These tests bound the indexing process's HEAP with
  # `max_heap_size`, so a regression kills the process instead of passing quietly.
  #
  # The cap is checked during GC, when the heap being grown and the one being
  # collected coexist, so it reads well above the live set. Measured on this
  # note (OTP 27, 3 runs each): float-list vectors held for the whole note are
  # killed even at 200 MB; the current code passes at 30 MB. 60 MB catches
  # that regression with room for GC/OTP variance; it is too coarse to pin the
  # per-batch JSON-fragment saving, which the local RSS repro measured instead.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Indexing

  setup :set_mox_global
  setup :verify_on_exit!

  @dims 1024
  @sparse_cap 80 * 1_048_576

  setup do
    bypass = Bypass.open()
    # Process-scoped (reaches the Task through `$callers`): deleting a global
    # `:qdrant_url` on exit would strip it from every later suite.
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    test_pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 200_000_000)

      if conn.method == "PUT" and String.ends_with?(conn.request_path, "/points") do
        send(test_pid, {:upsert, Jason.decode!(body)})
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp random_vector, do: for(_ <- 1..@dims, do: :rand.uniform() - 0.5)

  # ~2,000 chunks of plain prose: what a long transcript or book draft looks like.
  defp big_prose_note(user, vault) do
    para = String.duplicate("lorem ipsum dolor sit amet consectetur adipiscing elit ", 36)
    content = Enum.map_join(1..2_000, "\n\n", fn i -> "## Part #{i}\n\n" <> para end)
    Engram.Fixtures.insert_note!(user, vault, %{path: "Big/Transcript.md", content: content})
  end

  defp decrypted(note, user) do
    {:ok, n} = Engram.Crypto.maybe_decrypt_note_fields(note, user)
    n
  end

  defp run_with_heap_cap(cap_bytes, fun) do
    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{
          size: div(cap_bytes, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false
        })

        fun.()
      end)

    Task.yield(task, :timer.minutes(5)) || Task.shutdown(task)
  end

  test "indexing a 2,000-chunk note stays under a 60 MB heap", %{user: user, vault: vault} do
    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> random_vector() end)}
    end)

    note = big_prose_note(user, vault) |> decrypted(user)

    Process.flag(:trap_exit, true)
    result = run_with_heap_cap(60 * 1_048_576, fn -> Indexing.index_note(note, vault, user) end)

    assert {:ok, {:ok, count}} = result
    assert count >= 2_000
  end

  test "an embedder returning packed float32 is upserted as the same floats",
       %{user: user, vault: vault} do
    vec = for i <- 1..@dims, do: i / 1024 - 0.5
    packed = for x <- vec, into: <<>>, do: <<x::float-32-little>>

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> packed end)}
    end)

    note =
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "Packed.md",
        content: "# Packed\n\nA short note."
      })
      |> decrypted(user)

    assert {:ok, _} = Indexing.index_note(note, vault, user)
    assert_receive {:upsert, %{"points" => [%{"vector" => %{"dense" => dense}} | _]}}
    assert dense == vec
  end

  # Sparse vectors used to be the heap: two list cells and a boxed float per
  # term, ~48 B, held for the whole note. A note with a wide vocabulary (code,
  # identifiers, logs) has hundreds of terms per chunk. Measured on this note
  # (4.8 MB, 4,000 chunks): 28 MB of sparse lists live, killed even at a 160 MB
  # cap. Packed, they are off-heap binaries and the same note indexes under
  # 40 MB; 80 MB leaves room for GC/OTP variance.
  @tag timeout: :timer.minutes(5)
  test "a wide-vocabulary note's sparse vectors stay off the heap", %{user: user, vault: vault} do
    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    :rand.seed(:exsss, {1, 2, 3})
    word = fn -> for(_ <- 1..7, into: "", do: <<Enum.random(?a..?z)>>) end

    content =
      Enum.map_join(1..2_000, "\n\n", fn i ->
        "## Part #{i}\n\n" <> Enum.map_join(1..300, " ", fn _ -> word.() end)
      end)

    note =
      Engram.Fixtures.insert_note!(user, vault, %{path: "Big/Vocab.md", content: content})
      |> decrypted(user)

    Process.flag(:trap_exit, true)
    result = run_with_heap_cap(@sparse_cap, fn -> Indexing.index_note(note, vault, user) end)

    assert {:ok, {:ok, count}} = result
    assert count >= 2_000
  end

  test "upserted keyword vectors are the encoder's values, exactly", %{user: user, vault: vault} do
    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    text = "Ferritin ferritin iron panel, İstanbul ﬁle naïve 東京 0.75 x_y"

    note =
      Engram.Fixtures.insert_note!(user, vault, %{path: "Kw.md", content: text})
      |> decrypted(user)

    assert {:ok, _} = Indexing.index_note(note, vault, user)
    assert_receive {:upsert, %{"points" => [%{"vector" => %{"keyword" => keyword}}]}}

    {:ok, key} = Engram.Crypto.dek_filter_key(user)
    avgdl = Engram.KeywordIndex.Stats.avgdl(note.user_id, note.vault_id)
    {expected, _len} = Engram.KeywordIndex.QdrantSparse.encode_document(text, key, avgdl, nil)

    assert keyword == %{"indices" => expected.indices, "values" => expected.values}
  end

  test "upserted dense vectors are the embedder's values, exactly", %{user: user, vault: vault} do
    vec = for i <- 1..@dims, do: i / 1024 - 0.5

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> vec end)}
    end)

    note =
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "Small.md",
        content: "# Small\n\nA short note."
      })
      |> decrypted(user)

    assert {:ok, _} = Indexing.index_note(note, vault, user)
    assert_receive {:upsert, %{"points" => [%{"vector" => %{"dense" => dense}} | _]}}
    assert dense == vec
  end
end
