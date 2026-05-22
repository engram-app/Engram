defmodule Engram.Workers.MigrateUserProviderTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox
  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Repo
  alias Engram.Workers.MigrateUserProvider

  setup :verify_on_exit!

  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

    table = :ets.new(:worker_kms_stub, [:set, :public])

    stub(Engram.AwsKmsMock, :encrypt, fn pt, _ ->
      ct = :crypto.strong_rand_bytes(48)
      :ets.insert(table, {ct, pt})
      {:ok, ct}
    end)

    stub(Engram.AwsKmsMock, :decrypt, fn ct, _ ->
      case :ets.lookup(table, ct) do
        [{^ct, pt}] -> {:ok, pt}
        [] -> {:error, :context_mismatch}
      end
    end)

    stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
    :ok
  end

  defp user_with_local_dek! do
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    user
  end

  test "perform/1 happy path: returns :ok, rewraps user" do
    user = user_with_local_dek!()

    assert :ok =
             perform_job(MigrateUserProvider, %{
               "user_id" => user.id,
               "target_provider" => "aws_kms"
             })

    reloaded = Repo.one!(from(u in User, where: u.id == ^user.id), skip_tenant_check: true)
    assert reloaded.key_provider == "aws_kms"
  end

  test "perform/1 skipped (already at target) returns :ok" do
    user = user_with_local_dek!()

    :ok =
      perform_job(MigrateUserProvider, %{"user_id" => user.id, "target_provider" => "aws_kms"})

    assert :ok =
             perform_job(MigrateUserProvider, %{
               "user_id" => user.id,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:discard, :user_deleted} when user is missing" do
    assert {:discard, :user_deleted} =
             perform_job(MigrateUserProvider, %{
               "user_id" => 99_999_999,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:discard, :no_dek} when user has no encrypted_dek" do
    user = insert(:user)
    assert is_nil(user.encrypted_dek)

    assert {:discard, :no_dek} =
             perform_job(MigrateUserProvider, %{
               "user_id" => user.id,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:error, reason} for retryable KMS errors" do
    stub(Engram.AwsKmsMock, :encrypt, fn _, _ -> {:error, :throttled} end)
    user = user_with_local_dek!()

    assert {:error, {:kms_encrypt_failed, :throttled}} =
             perform_job(MigrateUserProvider, %{
               "user_id" => user.id,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:discard, {:invalid_args, …}} for malformed args" do
    assert {:discard, {:invalid_args, _}} = perform_job(MigrateUserProvider, %{"garbage" => 1})
  end

  test "perform/1 rejects unknown target_provider" do
    assert {:discard, {:unknown_target, "passphrase"}} =
             perform_job(MigrateUserProvider, %{"user_id" => 1, "target_provider" => "passphrase"})
  end
end
