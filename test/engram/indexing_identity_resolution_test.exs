defmodule Engram.IndexingIdentityResolutionTest do
  # Guard: indexing one note must resolve its user AT MOST ONCE.
  #
  # `Indexing.index_note/3` and `Indexing.prepare_index/3` both need the same
  # `%User{}`, and each used to call `Accounts.get_user!/1` for itself. On the
  # embed path that stacked with two more in `Workers.EmbedNote`, so a single
  # note cost up to FOUR identical round trips for a row that cannot change
  # mid-job. Measured in prod 2026-08-28: 2.1 `users` queries per job at ~13
  # jobs/sec, part of ~17 queries per job overall.
  #
  # A cache would have hidden this rather than fixed it — the call would still
  # be made, just against ETS. The fix is to resolve once and thread the
  # struct, and this test is what stops a future edit quietly re-adding a
  # lookup deep in the call graph where review will not see it. See #1502.
  #
  # Counting real queries rather than asserting on call sites: a grep-style
  # test passes while a helper three frames down re-fetches.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Indexing
  alias Engram.Notes

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Perf/Identity.md",
        "content" => "---\ntags: [perf]\n---\n# Identity\n\nResolve once, not four times.",
        "mtime" => 1_000.0
      })

    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  test "index_note/3 issues at most one users query when the caller supplies the user",
       %{bypass: bypass, note: note, vault: vault, user: user} do
    stub_embedder()
    stub_qdrant(bypass)

    # Freshly loaded, as the real caller does — `EmbedNote.perform/1` threads
    # the result of `get_user!/1`. A factory struct is not equivalent: it lacks
    # the encrypted DEK fields the index path needs, and passing one fails with
    # `:no_dek`. Worth knowing, because it is the trap in threading identity —
    # the struct you pass must be the one the callee would have fetched.
    fresh_user = Engram.Accounts.get_user!(user.id)

    {count, result} = count_user_queries(fn -> Indexing.index_note(note, vault, fresh_user) end)

    assert match?({:ok, _}, result), "index_note failed: #{inspect(result)}"

    assert count == 0,
           "index_note/3 was handed the user and still ran #{count} `users` quer#{plural(count)}.\n" <>
             "Something below it is re-resolving identity instead of using the struct it\n" <>
             "was given — thread it through rather than fetching again. See #1502."
  end

  test "index_note/2 resolves the user exactly once when the caller has none",
       %{bypass: bypass, note: note, vault: vault} do
    stub_embedder()
    stub_qdrant(bypass)

    {count, result} = count_user_queries(fn -> Indexing.index_note(note, vault) end)

    assert match?({:ok, _}, result), "index_note failed: #{inspect(result)}"

    assert count == 1,
           "index_note/2 ran #{count} `users` quer#{plural(count)}, expected exactly 1.\n" <>
             "The two-arg form resolves identity once at the top and threads it down; more\n" <>
             "than one means a nested call re-fetched, fewer means this test stopped\n" <>
             "observing the query it is supposed to guard. See #1502."
  end

  # The `users` budget above says nothing about `subscriptions`, and that is
  # where this path actually leaked: `IndexCap.within_cap?/2` (#1486) and
  # `SearchProfile.resolve/1` each resolve the tier, and on a bare `get_user!/1`
  # struct each costs its own round trip. EmbedNote never hit it because it
  # threads a `get_user_with_subscription/1` user down; the two-arg form,
  # which resolves its own, did — and nothing covered it. See #1502.
  test "index_note/2 issues NO subscriptions queries when it resolves its own user",
       %{bypass: bypass, note: note, vault: vault} do
    stub_embedder()
    stub_qdrant(bypass)

    {count, result} =
      count_queries("subscriptions", fn -> Indexing.index_note(note, vault) end)

    assert match?({:ok, _}, result), "index_note failed: #{inspect(result)}"

    assert count == 0,
           "index_note/2 ran #{count} `subscriptions` quer#{plural(count)}, expected 0.\n" <>
             "It resolves the user with `get_user_with_subscription!/1`, so the association\n" <>
             "is loaded and every downstream `effective_limit/2` reads it from the struct.\n" <>
             "A non-zero count means something re-loaded the user without the join."
  end

  # Counts Ecto queries against the `users` source for the duration of `fun`.
  # Ecto tags each query with its schema source, which is what the prod
  # `sum by (source) (rate(ecto_repo_query_total_time_milliseconds_count))`
  # measurement keys on — so this test counts the same thing the dashboard does.
  defp count_user_queries(fun), do: count_queries("users", fun)

  defp count_queries(source, fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measure, meta, _cfg ->
        if meta[:source] == source, do: send(test_pid, {ref, :users_query})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {drain(ref, 0), result}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, :users_query} -> drain(ref, acc + 1)
    after
      # NOT 0. Telemetry handlers run in the process that emits the query and
      # `send/2` to the test process is asynchronous, so a query emitted from a
      # spawned process can still be in flight when the work returns. With a
      # zero timeout we would undercount — and for a BUDGET assertion the
      # dangerous direction is a false PASS, not a false failure. 100ms is long
      # enough for an already-sent message and still instant in practice, since
      # the loop only waits once the queue is genuinely drained.
      100 -> acc
    end
  end

  defp plural(1), do: "y"
  defp plural(_), do: "ies"

  defp stub_embedder do
    Engram.MockEmbedder
    |> stub(:embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp stub_qdrant(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}, "status": "ok"}))
    end)
  end
end
