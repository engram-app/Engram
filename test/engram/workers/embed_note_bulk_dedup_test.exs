defmodule Engram.Workers.EmbedNoteBulkDedupTest do
  @moduledoc """
  `EmbedNote`'s `unique:` option is enforced by Oban's `insert/3` advisory lock.
  Bulk callers (`ReconcileEmbeddings`, batch upsert, `ReindexKeyword`) enqueue
  with `Oban.insert_all/2`, and **the basic engine ignores `unique` there** —
  bulk unique is an Oban Pro (Smart Engine) feature.

  That combination is a ratchet, not merely a duplicate. `ReconcileEmbeddings`
  selects notes whose `embed_hash != content_hash` and whose cooldown has
  lapsed; it never asks whether a job is already pending, because its own
  comment assumes "EmbedNote is uniq-deduped". So every backoff window adds
  ANOTHER job for a note whose job is still queued. Observed in dev on
  2026-08-25: 61,536 pending jobs for 4,266 notes, one note queued 184 times
  over five days.

  `reject_already_queued/1` is the guard. These tests pin the behaviour that
  makes the ratchet impossible.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  # Mirror of EmbedNote's @pending_states. NOT Oban's full :incomplete set —
  # `executing` is deliberately absent and gets its own test below.
  @pending ~w(scheduled available retryable)

  defp insert_job!(note_id, state) do
    now = DateTime.utc_now(:second)

    Repo.insert_all("oban_jobs", [
      %{
        state: state,
        queue: "embed",
        worker: "Engram.Workers.EmbedNote",
        args: %{"note_id" => note_id},
        inserted_at: now,
        scheduled_at: now
      }
    ])
  end

  defp pending_count(note_id) do
    from(j in "oban_jobs",
      where: j.worker == "Engram.Workers.EmbedNote",
      where: j.state in @pending,
      where: fragment("? ->> 'note_id' = ?", j.args, ^note_id),
      select: count(j.inserted_at)
    )
    |> Repo.one()
  end

  describe "reject_already_queued/1" do
    test "drops ids that already have an incomplete job" do
      queued = Ecto.UUID.generate()
      fresh = Ecto.UUID.generate()
      insert_job!(queued, "available")

      assert EmbedNote.reject_already_queued([queued, fresh]) == [fresh]
    end

    test "keeps ids whose only jobs are finished" do
      done = Ecto.UUID.generate()
      insert_job!(done, "completed")
      insert_job!(done, "discarded")
      insert_job!(done, "cancelled")

      assert EmbedNote.reject_already_queued([done]) == [done]
    end

    test "drops ids in every not-yet-started state, not just available" do
      for state <- @pending do
        id = Ecto.UUID.generate()
        insert_job!(id, state)

        assert EmbedNote.reject_already_queued([id]) == [],
               "a job in state #{state} must suppress a re-enqueue"
      end
    end

    test "an executing job does NOT suppress — it may have read the old content" do
      running = Ecto.UUID.generate()
      insert_job!(running, "executing")

      assert EmbedNote.reject_already_queued([running]) == [running],
             """
             Suppressing on `executing` would strand an edit made mid-embed: that job
             may already have read the previous content, and its `embed_hash` stamp is
             a no-op under the optimistic lock, so nothing would re-embed the new
             content until ReconcileEmbeddings swept it (~45 min).
             """
    end

    test "executing does not reopen the ratchet — the follow-up job suppresses the next tick" do
      note_id = Ecto.UUID.generate()
      insert_job!(note_id, "executing")

      # First tick is allowed through and lands an `available` job...
      assert EmbedNote.reject_already_queued([note_id]) == [note_id]
      insert_job!(note_id, "available")

      # ...which suppresses every later tick, so the pile-up caps at 2.
      assert EmbedNote.reject_already_queued([note_id]) == []
    end

    test "preserves input order and passes everything through when nothing is queued" do
      ids = for _ <- 1..5, do: Ecto.UUID.generate()
      assert EmbedNote.reject_already_queued(ids) == ids
    end

    test "is a no-op on an empty list and issues no query" do
      assert EmbedNote.reject_already_queued([]) == []
    end
  end

  describe "chunked lookup" do
    test "stays correct across chunk boundaries" do
      # Well past @lookup_chunk (50), with queued/fresh interleaved so a
      # per-chunk bug can't pass by accident.
      pairs =
        for i <- 1..120 do
          id = Ecto.UUID.generate()
          if rem(i, 3) == 0, do: insert_job!(id, "available")
          {id, rem(i, 3) == 0}
        end

      expected = for {id, queued?} <- pairs, not queued?, do: id
      ids = Enum.map(pairs, &elem(&1, 0))

      assert EmbedNote.reject_already_queued(ids) == expected
    end

    test "issues one query per chunk, not one per id" do
      ids = for _ <- 1..120, do: Ecto.UUID.generate()

      {:ok, agent} = Agent.start_link(fn -> 0 end)
      ref = make_ref()

      :telemetry.attach(
        "chunk-count-#{inspect(ref)}",
        [:engram, :repo, :query],
        fn _, _, %{query: q}, _ ->
          if q =~ "oban_jobs" and q =~ "note_id", do: Agent.update(agent, &(&1 + 1))
        end,
        nil
      )

      EmbedNote.reject_already_queued(ids)
      count = Agent.get(agent, & &1)
      :telemetry.detach("chunk-count-#{inspect(ref)}")

      # Exact, not an upper bound. Too many queries is the per-id-SELECT
      # regression; too few means the chunk grew past the ~50-id cliff where
      # Postgres abandons the expression index for a Seq Scan of the backlog.
      # Both directions are real, so both must fail here.
      assert count == 3,
             "120 ids must cost exactly ceil(120/#{50}) = 3 queries, got #{count}"
    end
  end

  describe "the ratchet it prevents" do
    test "repeated bulk enqueues of the same note never stack up" do
      note_id = Ecto.UUID.generate()

      # Simulate ReconcileEmbeddings ticking 10 times while the job never drains.
      for _tick <- 1..10 do
        note_id
        |> List.wrap()
        |> EmbedNote.reject_already_queued()
        |> Enum.map(&EmbedNote.new_debounced(&1, clamp: false))
        |> case do
          [] -> :ok
          changesets -> Oban.insert_all(changesets)
        end
      end

      assert pending_count(note_id) == 1,
             "ten bulk ticks must leave exactly one pending job, not ten"
    end
  end
end
