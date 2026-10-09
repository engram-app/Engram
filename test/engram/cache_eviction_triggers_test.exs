defmodule Engram.CacheEvictionTriggersTest do
  # NOTIFY is delivered on COMMIT only, and the SQL sandbox never commits, so
  # these tests write for real via unboxed_run and delete the user (cascade) in
  # an `after`, keeping the shared DB clean.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Repo

  @channels ~w(users_changed subscriptions_changed api_keys_changed api_key_vaults_changed vaults_changed)

  setup do
    {:ok, pid} = Postgrex.Notifications.start_link(Repo.config())
    for ch <- @channels, do: {:ok, _} = Postgrex.Notifications.listen(pid, ch)
    :ok
  end

  defp sql(query, params \\ []), do: Repo.query!(query, params)

  defp uuid(bin), do: Ecto.UUID.load!(bin)

  defp with_user(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      n = System.unique_integer([:positive])

      %{rows: [[id]]} =
        sql(
          "INSERT INTO users (email, created_at, updated_at) VALUES ($1, now(), now()) RETURNING id",
          ["trig_#{n}@example.com"]
        )

      try do
        fun.(uuid(id))
      after
        sql("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(uuid(id))])
      end
    end)
  end

  defp insert_vault(user_id) do
    %{rows: [[id]]} =
      sql(
        """
        INSERT INTO vaults (user_id, created_at, updated_at, name_ciphertext, name_nonce, name_hmac, slug)
        VALUES ($1, now(), now(), '\\x00', '\\x00', '\\x00', $2) RETURNING id
        """,
        [Ecto.UUID.dump!(user_id), "v#{System.unique_integer([:positive])}"]
      )

    uuid(id)
  end

  defp insert_api_key(user_id, hash) do
    %{rows: [[id]]} =
      sql(
        "INSERT INTO api_keys (user_id, key_hash, created_at) VALUES ($1, $2, now()) RETURNING id",
        [Ecto.UUID.dump!(user_id), hash]
      )

    uuid(id)
  end

  defp flush do
    receive do
      {:notification, _, _, _, _} -> flush()
    after
      300 -> :ok
    end
  end

  test "vaults: change_seq/updated_at-only update is silent; rename and insert/delete notify the user id" do
    with_user(fn user_id ->
      vault_id = insert_vault(user_id)
      assert_receive {:notification, _, _, "vaults_changed", ^user_id}, 1_000
      flush()

      sql(
        "UPDATE vaults SET change_seq = change_seq + 1, updated_at = now() WHERE id = $1",
        [Ecto.UUID.dump!(vault_id)]
      )

      refute_receive {:notification, _, _, "vaults_changed", _}, 300

      sql("UPDATE vaults SET slug = 'renamed' WHERE id = $1", [Ecto.UUID.dump!(vault_id)])
      assert_receive {:notification, _, _, "vaults_changed", ^user_id}, 1_000

      flush()
      sql("DELETE FROM vaults WHERE id = $1", [Ecto.UUID.dump!(vault_id)])
      assert_receive {:notification, _, _, "vaults_changed", ^user_id}, 1_000
    end)
  end

  test "users: UPDATE notifies the user id" do
    with_user(fn user_id ->
      flush()
      sql("UPDATE users SET suspended_at = now() WHERE id = $1", [Ecto.UUID.dump!(user_id)])
      assert_receive {:notification, _, _, "users_changed", ^user_id}, 1_000
    end)
  end

  test "subscriptions: INSERT notifies the user id" do
    with_user(fn user_id ->
      sql(
        """
        INSERT INTO subscriptions (user_id, paddle_customer_id, tier, created_at, updated_at)
        VALUES ($1, 'ctm_trig', 'starter', now(), now())
        """,
        [Ecto.UUID.dump!(user_id)]
      )

      assert_receive {:notification, _, _, "subscriptions_changed", ^user_id}, 1_000
    end)
  end

  test "api_keys: DELETE notifies the key_hash; last_used-only update is silent" do
    with_user(fn user_id ->
      hash = "trighash#{System.unique_integer([:positive])}"
      key_id = insert_api_key(user_id, hash)
      flush()

      sql("UPDATE api_keys SET last_used = now() WHERE id = $1", [Ecto.UUID.dump!(key_id)])
      refute_receive {:notification, _, _, "api_keys_changed", _}, 300

      sql("DELETE FROM api_keys WHERE id = $1", [Ecto.UUID.dump!(key_id)])
      assert_receive {:notification, _, _, "api_keys_changed", ^hash}, 1_000
    end)
  end

  test "api_key_vaults: INSERT notifies the api_key_id" do
    with_user(fn user_id ->
      vault_id = insert_vault(user_id)
      key_id = insert_api_key(user_id, "trighash#{System.unique_integer([:positive])}")
      flush()

      sql("INSERT INTO api_key_vaults (api_key_id, vault_id) VALUES ($1, $2)", [
        Ecto.UUID.dump!(key_id),
        Ecto.UUID.dump!(vault_id)
      ])

      assert_receive {:notification, _, _, "api_key_vaults_changed", ^key_id}, 1_000
    end)
  end
end
