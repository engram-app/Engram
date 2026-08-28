defmodule Engram.Workers.EmbedNoteQueryBudgetTest do
  # Guard: one EmbedNote job resolves its user with ONE `users` query.
  #
  # The job used to spend two before doing any work — `RotationGate.check/1`
  # selecting `{id, dek_rotation_locked_at}`, then `Accounts.get_user!/1` for
  # the full row — plus up to two more further down in `Indexing`. Measured in
  # prod 2026-08-28 at 2.1 `users` queries per job, part of ~17 queries/job at
  # ~13 jobs/sec.
  #
  # The full row already carries `dek_rotation_locked_at`, so one read answers
  # both questions. `RotationGate.check_user/1` gates on the same struct that
  # is then used, which also closes a window the two-query form left open: a
  # rotation starting between the two reads let a job pass a pre-rotation check
  # and then operate on a post-rotation user.
  #
  # This is a budget, not a micro-assertion. It is worded as "at most" because
  # the point is that the number cannot silently grow — a future edit adding an
  # innocuous `get_user!` deep in the call graph is exactly what this catches,
  # and review will not. See #1502.
  use Engram.DataCase, async: false

  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Mox

  alias Engram.Accounts.User
  alias Engram.Notes
  alias Engram.Workers.EmbedNote

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}, "status": "ok"}))
    end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Perf/Budget.md",
        "content" => "---\ntags: [perf]\n---\n# Budget\n\nOne user read per job.",
        "mtime" => 1_000.0
      })

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    %{user: user, vault: vault, note: note, bypass: bypass}
  end

  test "a full EmbedNote job issues at most one users query", %{note: note} do
    {count, result} =
      count_queries("users", fn -> perform_job(EmbedNote, %{note_id: note.id}) end)

    assert result == :ok, "job did not succeed: #{inspect(result)}"

    assert count <= 1,
           "EmbedNote ran #{count} `users` queries for one note, budget is 1.\n" <>
             "The user is resolved once at the top of perform/1 and threaded down — the\n" <>
             "rotation gate, the budget gate, the decrypt and both halves of Indexing all\n" <>
             "take the struct. Something re-resolved it. See #1502."
  end

  test "a full EmbedNote job issues NO subscriptions queries", %{note: note} do
    {count, result} =
      count_queries("subscriptions", fn -> perform_job(EmbedNote, %{note_id: note.id}) end)

    assert result == :ok, "job did not succeed: #{inspect(result)}"

    assert count == 0,
           "EmbedNote ran #{count} `subscriptions` quer#{if count == 1, do: "y", else: "ies"}, expected 0.\n" <>
             "The user is loaded with `get_user_with_subscription/1`, so the association is\n" <>
             "already populated and `Billing.get_subscription/1` short-circuits. A non-zero\n" <>
             "count means something re-loaded the user without the join — the budget gate\n" <>
             "resolves the tier twice, so this silently doubles. See #1502."
  end

  test "the rotation gate still blocks, reading the lock from the single fetch",
       %{note: note, user: user, bypass: bypass} do
    # This job must snooze BEFORE touching Qdrant, so the setup's Bypass
    # expectation is deliberately never met. `pass/1` records that as intended
    # rather than a missed request — the absence of an HTTP call is the
    # assertion, not a failure.
    Bypass.pass(bypass)

    # Set the column directly: RotationLock.acquire/2 takes a Postgres advisory
    # lock, which does not survive a Sandbox checkout in a non-async test.
    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      [set: [dek_rotation_locked_at: DateTime.utc_now()]],
      skip_tenant_check: true
    )

    # No embedder expectation — reaching the embedder would fail verify_on_exit!
    assert {:snooze, 60} = perform_job(EmbedNote, %{note_id: note.id})
  end

  # Counts Ecto queries against one source. Keys on `meta.source`, the same
  # field the prod `sum by (source) (rate(ecto_..._count))` measurement uses, so
  # this test and the dashboard count the same thing.
  defp count_queries(source, fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _e, _m, meta, _c ->
        if meta[:source] == source, do: send(test_pid, {ref, :hit})
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
      {^ref, :hit} -> drain(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
