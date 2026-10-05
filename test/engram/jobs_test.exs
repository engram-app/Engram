defmodule Engram.JobsTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Jobs
  alias Engram.Workers.RefreshKeywordVectors

  defp job!(note_id, state) do
    %{note_id: note_id, user_id: Ecto.UUID.generate()}
    |> RefreshKeywordVectors.new()
    |> Oban.insert!()
    |> Ecto.Changeset.change(state: state)
    |> Repo.update!()
  end

  describe "reject_pending/3" do
    test "drops ids with a pending job of that worker, keeps the rest" do
      [queued, running, done, fresh] = for _ <- 1..4, do: Ecto.UUID.generate()
      job!(queued, "available")
      job!(running, "executing")
      job!(done, "completed")

      assert Jobs.reject_pending(RefreshKeywordVectors, [queued, running, done, fresh]) ==
               [done, fresh]
    end

    test "executing: false lets a running job through" do
      running = Ecto.UUID.generate()
      job!(running, "executing")

      assert Jobs.reject_pending(RefreshKeywordVectors, [running], executing: false) ==
               [running]
    end

    test "promote_to lowers a worse-ranked pending job's priority" do
      id = Ecto.UUID.generate()
      job = job!(id, "available") |> Ecto.Changeset.change(priority: 9) |> Repo.update!()

      assert Jobs.reject_pending(RefreshKeywordVectors, [id], promote_to: 0) == []
      assert Repo.reload!(job).priority == 0
    end

    test "looks up past one query's parameter limit" do
      ids = for _ <- 1..70_000, do: Ecto.UUID.generate()
      last = List.last(ids)
      job!(last, "scheduled")
      assert length(Jobs.reject_pending(RefreshKeywordVectors, ids)) == 69_999
    end

    test "another worker's job does not count" do
      id = Ecto.UUID.generate()
      job!(id, "available")
      assert Jobs.reject_pending(Engram.Workers.RebuildStaleNote, [id]) == [id]
    end
  end

  # The index only helps if the planner can match it: the key and the states
  # must be literals in the SQL, not parameters. With seq scans disabled, a
  # plan that still avoids the index means the query cannot use it.
  describe "oban_jobs_pending_note_id_index" do
    for executing? <- [true, false] do
      test "backs the lookup (executing: #{executing?})" do
        query =
          Jobs.pending_query_for_test(
            "Engram.Workers.RebuildStaleNote",
            [Ecto.UUID.generate()],
            unquote(executing?)
          )

        {sql, params} = Repo.to_sql(:all, query)

        plan =
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL enable_seqscan = off")
            Repo.query!("EXPLAIN " <> sql, params).rows |> List.flatten() |> Enum.join("\n")
          end)

        assert {:ok, text} = plan
        assert text =~ "oban_jobs_pending_note_id_index", text
      end
    end
  end
end
