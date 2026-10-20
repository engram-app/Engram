defmodule Engram.IndexingVectorCacheTest do
  @moduledoc """
  The vector cache in the embed path (chunker v5 Task 12.2): Voyage is paid
  once per text, across notes (F2), across a 429 and a retry on another node
  (H5), and across a crash between the embed and the commit (H9). Hits are
  never charged, and a note past one pass's embed budget finishes over
  several passes instead of going keyword-only.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Indexing
  alias Engram.Indexing.RetainedVectors
  alias Engram.Notes
  alias Engram.UsageMeters

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    Application.put_env(:engram, :vector_cache_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :vector_cache_enabled) end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  # Sections over 512 B so min512 coalescing leaves each one its own chunk.
  defp body(n, tag \\ "") do
    for i <- 1..n, into: "" do
      "## Section #{i}\n\n#{tag}Paragraph #{i}. #{String.duplicate("words that fill it ", 45)}\n\n"
    end
  end

  defp put_note(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    {:ok, note} =
      note
      |> Repo.reload!(skip_tenant_check: true)
      |> Engram.Crypto.maybe_decrypt_note_fields(Repo.reload!(user, skip_tenant_check: true))

    note
  end

  # Records every call's text count and bytes. `fail` decides per call
  # (1-based): `false` embeds, `true` is a 429, anything else is returned.
  defp stub_embedder(fail \\ fn _call -> false end) do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

      case fail.(call) do
        false ->
          send(test, {:embedded, length(texts), texts |> Enum.map(&byte_size/1) |> Enum.sum()})
          {:ok, Enum.map(texts, fn _ -> [0.5, 0.25, -0.125] end)}

        true ->
          {:error, {429, "rate limited"}}

        error ->
          error
      end
    end)
  end

  defp embedded, do: calls() |> Enum.map(&elem(&1, 0)) |> Enum.sum()

  # `{texts, bytes}` per successful embed call since the last drain.
  defp calls do
    receive do
      {:embedded, n, bytes} -> [{n, bytes} | calls()]
    after
      0 -> []
    end
  end

  defp tokens(calls),
    do: calls |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> UsageMeters.estimate_tokens()

  defp meter_opts(user) do
    test = self()

    [
      reserve_tokens: fn t ->
        send(test, {:reserved, t})
        UsageMeters.reserve_embed_tokens(user.id, t, 1_000_000_000)
      end,
      release_tokens: fn t ->
        send(test, {:released, t})
        UsageMeters.release_embed_tokens(user.id, t)
      end
    ]
  end

  defp drained(tag) do
    receive do
      {^tag, t} -> t + drained(tag)
    after
      0 -> 0
    end
  end

  defp enable(key) do
    Application.put_env(:engram, key, true)
    on_exit(fn -> Application.delete_env(:engram, key) end)
  end

  defp small_pass_budget do
    Application.put_env(:engram, :max_pass_embed_bytes, 3_000)
    on_exit(fn -> Application.delete_env(:engram, :max_pass_embed_bytes) end)
  end

  # Every chunk's fingerprint stays KNOWN (moved into `member_hmacs`) but no
  # row can be reused (no `context_hmac`), and the cache is empty: the next
  # pass re-embeds them all and `changed_tokens/2` counts none of them.
  defp known_but_unreusable(note) do
    Repo.query!(
      "UPDATE chunks SET member_hmacs = ARRAY[left(context_hmac, 16)], context_hmac = NULL WHERE note_id = $1",
      [Ecto.UUID.dump!(note.id)]
    )

    Repo.query!("DELETE FROM embedding_cache")
  end

  defp cache_rows,
    do: Repo.query!("SELECT count(*) FROM embedding_cache").rows |> hd() |> hd()

  test "F2: identical prose in another folder embeds nothing and is charged nothing", ctx do
    stub_embedder()
    content = body(3)

    a = put_note(ctx.user, ctx.vault, "Work/Plan.md", content)
    assert {:ok, _} = Indexing.index_note(a, ctx.vault)
    first = embedded()
    assert first > 0
    assert cache_rows() == first

    b = put_note(ctx.user, ctx.vault, "Home/Plan.md", content)
    test = self()
    reserve = fn tokens -> send(test, {:reserved, tokens}) && true end

    assert {:ok, _count, 0, true} =
             Indexing.index_note_with_usage(b, ctx.vault, nil, reserve_tokens: reserve)

    assert embedded() == 0
    refute_received {:reserved, _}
  end

  test "H5: a 429 on request 2 and a retry on another node pay each text once", ctx do
    stub_embedder(&(&1 == 2))
    note = put_note(ctx.user, ctx.vault, "Big.md", body(300))

    assert {:error, {429, _}} = Indexing.index_note(note, ctx.vault)
    paid_first = embedded()
    assert paid_first > 0, "request 1 should have been cached"

    # Another node: nothing retained in memory.
    RetainedVectors.forget({note.id, nil})
    assert {:ok, count} = Indexing.index_note(note, ctx.vault)

    assert paid_first + embedded() == count
    assert cache_rows() == count
  end

  test "H9: a crash after the embed and before the commit makes the retry free", ctx do
    stub_embedder()
    note = put_note(ctx.user, ctx.vault, "Crash.md", body(4))

    assert_raise RuntimeError, fn ->
      Indexing.index_note_with_usage(note, ctx.vault, nil,
        in_commit: fn _, _, _ -> raise "killed before commit" end
      )
    end

    paid = embedded()
    assert paid > 0

    RetainedVectors.forget({note.id, nil})
    assert {:ok, ^paid} = Indexing.index_note(note, ctx.vault)
    assert embedded() == 0
  end

  test "a note past one pass's embed budget finishes densely over several passes", ctx do
    stub_embedder()
    Application.put_env(:engram, :max_pass_embed_bytes, 3_000)
    on_exit(fn -> Application.delete_env(:engram, :max_pass_embed_bytes) end)
    note = put_note(ctx.user, ctx.vault, "Long.md", body(8))

    passes =
      Stream.repeatedly(fn -> Indexing.index_note(note, ctx.vault) end)
      |> Enum.reduce_while(1, fn
        {:error, :embed_continues}, n when n < 20 -> {:cont, n + 1}
        result, n -> {:halt, {n, result}}
      end)

    assert {n, {:ok, count}} = passes
    assert n > 1
    assert embedded() == count
  end

  test "flag off: the cache is never read or written", ctx do
    Application.put_env(:engram, :vector_cache_enabled, false)
    stub_embedder()
    content = body(2)

    assert {:ok, n} =
             Indexing.index_note(put_note(ctx.user, ctx.vault, "A/X.md", content), ctx.vault)

    assert {:ok, ^n} =
             Indexing.index_note(put_note(ctx.user, ctx.vault, "B/X.md", content), ctx.vault)

    assert embedded() == 2 * n
    assert cache_rows() == 0
  end

  test "meter: a mid-note 429 keeps the paid batch charged; the retry charges the rest; total = sent, once",
       ctx do
    stub_embedder(&(&1 == 2))
    note = put_note(ctx.user, ctx.vault, "Meter.md", body(300))
    opts = meter_opts(ctx.user)

    assert {:error, {429, _}} = Indexing.index_note_with_usage(note, ctx.vault, nil, opts)
    first = calls()
    assert [_one_batch] = first
    reserved = drained(:reserved)
    released = drained(:released)
    assert reserved - released == tokens(first), "the cached batch must stay charged"
    assert UsageMeters.lifetime_embed_tokens(ctx.user.id) == tokens(first)

    RetainedVectors.forget({note.id, nil})
    assert {:ok, count, _bytes, true} = Indexing.index_note_with_usage(note, ctx.vault, nil, opts)
    retry = calls()
    assert drained(:reserved) == tokens(retry)
    assert drained(:released) == 0

    assert UsageMeters.lifetime_embed_tokens(ctx.user.id) == tokens(first) + tokens(retry)
    assert (first ++ retry) |> Enum.map(&elem(&1, 0)) |> Enum.sum() == count
  end

  test "budget on: a changed chunk that is a cache hit is never charged", ctx do
    enable(:index_budget_enabled)
    stub_embedder()
    s3 = "## Fresh\n\nBrand new prose. #{String.duplicate("never seen before here ", 40)}\n\n"

    a = put_note(ctx.user, ctx.vault, "Work/Plan.md", body(2))
    assert {:ok, _} = Indexing.index_note(a, ctx.vault)
    # Its two chunks stay KNOWN but must re-embed and miss the cache: our
    # maintenance, not the user's change.
    known_but_unreusable(a)
    # The one changed chunk is already cached, through another note.
    c = put_note(ctx.user, ctx.vault, "Home/Plan.md", s3)
    assert {:ok, _} = Indexing.index_note(c, ctx.vault)
    _ = calls()

    a = put_note(ctx.user, ctx.vault, "Work/Plan.md", body(2) <> s3)

    assert {:ok, _, _, true} =
             Indexing.index_note_with_usage(a, ctx.vault, nil, meter_opts(ctx.user))

    assert [{2, _}] = calls(), "only the two maintenance misses go to Voyage"
    refute_received {:reserved, _}
  end

  test "flag off with the budget on: the pass budget still truncates to keyword-only", ctx do
    Application.put_env(:engram, :vector_cache_enabled, false)
    enable(:index_budget_enabled)
    small_pass_budget()
    stub_embedder()
    note = put_note(ctx.user, ctx.vault, "Off.md", body(8))

    assert {:ok, count} = Indexing.index_note(note, ctx.vault)
    sent = embedded()
    assert sent > 0 and sent < count
    assert cache_rows() == 0
  end

  test "EmbedNote: the keyword-only fallback snoozes on :embed_continues, burning no attempt",
       ctx do
    enable(:index_budget_enabled)
    small_pass_budget()
    stub_embedder()
    note = put_note(ctx.user, ctx.vault, "TooLong.md", body(8))

    # Fully indexed, then every chunk known-but-pointless and uncached, so a
    # refused reservation (charge 0) still runs dense and runs past the budget.
    passes =
      Stream.repeatedly(fn -> Indexing.index_note(note, ctx.vault) end)
      |> Enum.find(&match?({:ok, _}, &1))

    assert {:ok, _} = passes
    known_but_unreusable(note)
    stub_embedder(&(&1 == 1 && {:error, {:permanent, :input_too_long}}))

    assert {:snooze, 1} =
             perform_job(Engram.Workers.EmbedNote, %{note_id: note.id, user_id: ctx.user.id})
  end
end
