defmodule Engram.UsageMetersBucketConcurrencyTest do
  # Truly concurrent takes. Sandbox tasks share the owner's one connection, so
  # their statements run one after another and prove only the arithmetic. Here
  # every take runs on its own connection, outside the sandbox, so the
  # `ON CONFLICT ... WHERE` row lock is what keeps two takes from spending the
  # same tokens. The user is deleted (cascade) in an `after`.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Repo
  alias Engram.UsageMeters

  @cap 6_000_000

  test "concurrent takes on separate connections never spend the same tokens twice" do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[id]]} =
        Repo.query!(
          "INSERT INTO users (email, created_at, updated_at) VALUES ($1, now(), now()) RETURNING id",
          ["bucket_#{System.unique_integer([:positive])}@example.com"]
        )

      user_id = Ecto.UUID.load!(id)

      try do
        # Seed the row, so every take below races on the UPDATE branch.
        {:ok, _} = UsageMeters.bucket_take(user_id, 1, @cap)

        results =
          1..20
          |> Task.async_stream(
            fn _ ->
              Sandbox.unboxed_run(Repo, fn ->
                UsageMeters.bucket_take(user_id, 1_000_000, @cap)
              end)
            end,
            max_concurrency: 10,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, r} -> r end)

        # 6M - 1 holds five whole millions, whatever the interleaving.
        assert Enum.count(results, &match?({:ok, _}, &1)) == 5
        assert Enum.count(results, &(&1 == {:error, :bucket_empty})) == 15
        assert UsageMeters.bucket_available(user_id, @cap) < 1_000_000
      after
        Repo.query!("DELETE FROM users WHERE id = $1", [id])
      end
    end)
  end
end
