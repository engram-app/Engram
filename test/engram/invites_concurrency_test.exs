defmodule Engram.InvitesConcurrencyTest do
  use Engram.DataCase, async: false
  alias Engram.Invites

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Engram.Repo, {:shared, self()})
    :ok
  end

  test "N concurrent redemptions of a max_uses=2 invite yield exactly 2 successes" do
    admin = insert(:user, role: "admin")
    {:ok, {raw, _}} = Invites.create_invite(admin, %{max_uses: 2})

    results =
      1..10
      |> Task.async_stream(fn _ -> Invites.redeem(raw) end,
        max_concurrency: 10,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
  end
end
