defmodule Engram.Notes.FrontmatterKeysRaceTest do
  @moduledoc """
  Concurrent allocation on REAL, separately committing connections:
  `Engram.DataCase` runs every task on one sandbox connection, which would
  serialize the race away. Rows outlive the test, hence the cleanup.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Crypto
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Repo
  alias Engram.Vector.FilterId

  setup do
    real_checkout!()
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    on_exit(fn -> cleanup(user.id) end)
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    %{user: user, dek: dek, fk: fk}
  end

  defp real_checkout! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  defp cleanup(user_id) do
    real_checkout!()
    Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user_id)])
  end

  test "parallel passes over overlapping keys agree on dense, unique ids", ctx do
    keys = for i <- 1..30, do: "key#{i}"

    results =
      1..8
      |> Enum.map(fn n ->
        # Each pass sees an overlapping, shifted slice.
        slice = keys |> Enum.drop(rem(n * 3, 10)) |> Enum.take(20)
        names = Map.new(slice, &{FilterId.key_hmac(ctx.fk, &1), &1})

        Task.async(fn ->
          real_checkout!()
          {ids, 0} = FrontmatterKeys.resolve(ctx.user.id, ctx.dek, names)
          ids
        end)
      end)
      |> Task.await_many(30_000)

    merged = Enum.reduce(results, %{}, &Map.merge(&2, &1, fn _k, a, b -> a == b && a end))
    assert Enum.all?(Map.values(merged), &is_integer/1), "two passes saw different ids"

    ids = merged |> Map.values() |> Enum.sort()
    assert ids == Enum.to_list(64..(64 + length(ids) - 1))
  end
end
