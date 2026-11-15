defmodule Engram.UsageMetersDayConcurrencyTest do
  # Two nodes racing on one user's last ceiling tokens. As in
  # `usage_meters_bucket_concurrency_test.exs`, every take runs on its own
  # connection outside the sandbox, so the `ON CONFLICT ... WHERE` row lock is
  # what keeps two takes from spending the same tokens. The user is deleted
  # (cascade) in an `after`.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Repo
  alias Engram.UsageMeters

  @ceiling 5_000_001

  test "concurrent takes on separate connections never pass the ceiling" do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[id]]} =
        Repo.query!(
          "INSERT INTO users (email, created_at, updated_at) VALUES ($1, now(), now()) RETURNING id",
          ["day_#{System.unique_integer([:positive])}@example.com"]
        )

      user_id = Ecto.UUID.load!(id)

      try do
        # Seed the row, so every take below races on the UPDATE branch.
        {:ok, 1} = UsageMeters.day_take(user_id, 1, @ceiling)

        results =
          1..20
          |> Task.async_stream(
            fn _ ->
              Sandbox.unboxed_run(Repo, fn ->
                UsageMeters.day_take(user_id, 1_000_000, @ceiling)
              end)
            end,
            max_concurrency: 10,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, r} -> r end)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 5
        assert Enum.count(results, &(&1 == {:error, :ceiling})) == 15
        assert UsageMeters.day_used(user_id) == @ceiling
      after
        Repo.query!("DELETE FROM users WHERE id = $1", [id])
      end
    end)
  end
end
