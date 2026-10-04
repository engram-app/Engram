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
