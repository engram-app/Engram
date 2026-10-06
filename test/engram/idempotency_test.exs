defmodule Engram.IdempotencyTest do
  @moduledoc """
  PG-backed idempotency store (#862). The previous ETS cache was node-local
  (a retry routed to the other Fargate task re-executed the batch — the key
  was defeated by the LB) and globally keyed (not user-scoped). Rows are
  user-scoped, DEK-encrypted at rest (batch responses carry plaintext note
  paths), and expire via the daily prune worker.
  """
  use Engram.DataCase, async: true

  alias Engram.Idempotency

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    other = insert(:user)
    {:ok, other} = Engram.Crypto.ensure_user_dek(other)
    %{user: user, other: other}
  end

  @scope %{
    vault_id: "00000000-0000-7000-8000-00000000000a",
    route: "POST /api/notes/batch-delete"
  }

  defp key, do: Ecto.UUID.generate()

  test "remember/lookup round-trips through Postgres", %{user: user} do
    k = key()

    :ok =
      Idempotency.remember(user, k, @scope, %{
        status: 200,
        body: %{"results" => [%{"ok" => true}]}
      })

    assert {:ok, %{status: 200, body: %{"results" => [%{"ok" => true}]}}} =
             Idempotency.lookup(user, k, @scope)
  end

  test "lookup is user-scoped — another user cannot replay the key", %{
    user: user,
    other: other
  } do
    k = key()
    :ok = Idempotency.remember(user, k, @scope, %{status: 200, body: %{"secret" => true}})

    assert :miss = Idempotency.lookup(other, k, @scope)
  end

  test "unknown key misses", %{user: user} do
    assert :miss = Idempotency.lookup(user, key(), @scope)
  end

  test "expired entries miss", %{user: user} do
    k = key()
    :ok = Idempotency.remember(user, k, @scope, %{status: 200, body: %{}}, ttl_ms: -1_000)
    assert :miss = Idempotency.lookup(user, k, @scope)
  end

  test "response body is ciphertext at rest", %{user: user} do
    k = key()

    :ok =
      Idempotency.remember(user, k, @scope, %{status: 200, body: %{"path" => "Secret/plans.md"}})

    {:ok, key_bin} = Ecto.UUID.dump(k)

    %{rows: [[ciphertext]]} =
      Repo.query!(
        "SELECT response_ciphertext FROM idempotency_keys WHERE key = $1",
        [key_bin]
      )

    refute ciphertext =~ "Secret/plans.md"
    assert {:ok, %{body: %{"path" => "Secret/plans.md"}}} = Idempotency.lookup(user, k, @scope)
  end

  test "duplicate remember keeps the first response", %{user: user} do
    k = key()
    :ok = Idempotency.remember(user, k, @scope, %{status: 200, body: %{"attempt" => 1}})
    :ok = Idempotency.remember(user, k, @scope, %{status: 200, body: %{"attempt" => 2}})

    assert {:ok, %{body: %{"attempt" => 1}}} = Idempotency.lookup(user, k, @scope)
  end

  test "prune_expired/0 deletes expired rows across users, keeps live ones", %{
    user: user,
    other: other
  } do
    dead_a = key()
    dead_b = key()
    alive = key()
    :ok = Idempotency.remember(user, dead_a, @scope, %{status: 200, body: %{}}, ttl_ms: -1_000)
    :ok = Idempotency.remember(other, dead_b, @scope, %{status: 200, body: %{}}, ttl_ms: -1_000)
    :ok = Idempotency.remember(user, alive, @scope, %{status: 200, body: %{}})

    assert {:ok, 2} = Idempotency.prune_expired()
    assert {:ok, _} = Idempotency.lookup(user, alive, @scope)
  end

  # #1869: the key alone matched, so a credential scoped to vault B could
  # replay vault A's cached batch response (plaintext note paths).
  test "lookup is vault-scoped — another vault cannot replay the key", %{user: user} do
    k = key()
    :ok = Idempotency.remember(user, k, @scope, %{status: 200, body: %{"secret" => true}})

    other_vault = %{@scope | vault_id: Ecto.UUID.generate()}
    assert :miss = Idempotency.lookup(user, k, other_vault)
  end

  test "lookup is route-scoped — another endpoint cannot replay the key", %{user: user} do
    k = key()
    :ok = Idempotency.remember(user, k, @scope, %{status: 200, body: %{}})

    assert :miss = Idempotency.lookup(user, k, %{@scope | route: "POST /api/folders/batch-move"})
  end

  test "legacy rows with no vault recorded miss", %{user: user} do
    k = key()
    :ok = Idempotency.remember(user, k, @scope, %{status: 200, body: %{}})
    {:ok, key_bin} = Ecto.UUID.dump(k)

    Repo.query!("UPDATE idempotency_keys SET vault_id = NULL, route = NULL WHERE key = $1", [
      key_bin
    ])

    assert :miss = Idempotency.lookup(user, k, @scope)
  end
end
