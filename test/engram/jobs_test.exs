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

    test "finds a pending job at the end of a long id list" do
      ids = for _ <- 1..500, do: Ecto.UUID.generate()
      last = List.last(ids)
      job!(last, "scheduled")
      assert length(Jobs.reject_pending(RefreshKeywordVectors, ids)) == 499
    end

    test "another worker's job does not count" do
      id = Ecto.UUID.generate()
      job!(id, "available")
      assert Jobs.reject_pending(Engram.Workers.RebuildStaleNote, [id]) == [id]
    end
  end

  # The index only helps if the planner can match it: the key and the states
  # must be literals in the SQL, not parameters. A plain EXPLAIN with bound
  # values cannot tell: Postgres plans a one-off statement with the values
  # inlined, so a parameter matches the partial predicate there. A prepared
  # statement under a forced generic plan keeps every parameter opaque, which
  # is how a parameter would reach the planner for a reused query plan.
  describe "oban_jobs_pending_note_id_index" do
    for executing? <- [true, false] do
      test "backs the lookup under a generic plan (executing: #{executing?})" do
        # A pending backlog, so the state index alone is not the cheap path.
        Oban.insert_all(
          for _ <- 1..2_000,
              do: RefreshKeywordVectors.new(%{note_id: Ecto.UUID.generate(), user_id: "u"})
        )

        query =
          Jobs.pending_query_for_test(
            "Engram.Workers.RefreshKeywordVectors",
            [Ecto.UUID.generate()],
            unquote(executing?)
          )

        {sql, params} = Repo.to_sql(:all, query)
        # Literals in EXECUTE's argument list: the generic plan ignores them.
        args = Enum.map_join(params, ", ", &literal/1)

        plan =
          Repo.transaction(fn ->
            Repo.query!("ANALYZE oban_jobs")
            Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")
            Repo.query!("SET LOCAL enable_seqscan = off")
            Repo.query!("PREPARE pending_lookup AS " <> sql)

            try do
              Repo.query!("EXPLAIN EXECUTE pending_lookup(#{args})").rows
              |> List.flatten()
              |> Enum.join("\n")
            after
              Repo.query!("DEALLOCATE pending_lookup")
            end
          end)

        assert {:ok, text} = plan
        assert text =~ "oban_jobs_pending_note_id_index", text
      end
    end
  end

  defp literal(list) when is_list(list),
    do: "ARRAY[" <> Enum.map_join(list, ", ", &literal/1) <> "]::text[]"

  defp literal(value) when is_binary(value), do: "'" <> value <> "'"
end
