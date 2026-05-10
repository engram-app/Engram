defmodule Engram.Crypto.EnsureUserDekRaceTest do
  # T3.1 / C1 — `Engram.Crypto.ensure_user_dek/1` provisioned a wrapped DEK
  # via reload-then-update without a transaction or row lock. Two concurrent
  # first-writes for the same user both observed `encrypted_dek: nil`, both
  # generated a fresh DEK, both updated; last-write wins and any ciphertext
  # written under the loser's DEK becomes permanently unreadable.
  #
  # The fix wraps the reload + update in `Repo.transaction` with
  # `lock: "FOR UPDATE"` on the user row. With ExUnit's shared sandbox the
  # tasks' DB ops serialize through a single connection — so this test does
  # not "trigger" the race at the SQL level. What it DOES verify is the
  # structural invariant the fix guarantees: parallel `ensure_user_dek/1`
  # calls for the same user return the same wrapped blob, and the row in DB
  # has exactly one stable wrapped value at the end. A regression that
  # removed the transaction/lock would still pass under sandbox serialization;
  # the integration story for true concurrency lives in the Phase B / load
  # test harness, not in this unit suite. Documenting that limit here so
  # future readers don't expect this test to detect a race in isolation.
  use Engram.DataCase, async: false

  alias Engram.Crypto

  setup do
    user = insert(:user)
    {:ok, user: user}
  end

  test "parallel ensure_user_dek/1 calls converge on a single wrapped DEK", %{user: user} do
    parent = self()

    results =
      1..4
      |> Task.async_stream(
        fn _ ->
          # Allow the spawned task to use the parent's sandbox connection.
          Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, parent, self())
          Crypto.ensure_user_dek(user)
        end,
        max_concurrency: 4,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # Every call must succeed.
    assert Enum.all?(results, &match?({:ok, %Engram.Accounts.User{}}, &1))

    # Every call must return the same wrapped DEK blob.
    wrapped_blobs =
      results
      |> Enum.map(fn {:ok, u} -> u.encrypted_dek end)
      |> Enum.uniq()

    assert length(wrapped_blobs) == 1,
           "expected one stable wrapped DEK across 4 concurrent calls, got #{length(wrapped_blobs)}"

    # And the row in DB must agree.
    reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
    assert reloaded.encrypted_dek == hd(wrapped_blobs)
  end

  test "sequential ensure_user_dek/1 calls are idempotent", %{user: user} do
    {:ok, u1} = Crypto.ensure_user_dek(user)
    {:ok, u2} = Crypto.ensure_user_dek(user)
    assert u1.encrypted_dek == u2.encrypted_dek
  end
end
