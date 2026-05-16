defmodule Engram.Crypto.ProviderMigrationTest do
  use Engram.DataCase, async: false

  import Mox
  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.ProviderMigration
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    prev_provider = Application.get_env(:engram, :key_provider)
    prev_client = Application.get_env(:engram, :aws_kms_client)
    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

    on_exit(fn ->
      Application.put_env(:engram, :key_provider, prev_provider)
      Application.put_env(:engram, :aws_kms_client, prev_client)
    end)

    :ok
  end

  defp stub_kms_roundtrip do
    table = :ets.new(:mig_kms_stub, [:set, :public])

    stub(Engram.AwsKmsMock, :encrypt, fn pt, _ctx ->
      ct = :crypto.strong_rand_bytes(48)
      :ets.insert(table, {ct, pt})
      {:ok, ct}
    end)

    stub(Engram.AwsKmsMock, :decrypt, fn ct, _ctx ->
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

  describe "migrate_user/2 Local→KMS" do
    test "rewraps blob with KMS provider tag and stamps key_provider" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()
      original_blob = user.encrypted_dek

      assert :ok = ProviderMigration.migrate_user(user.id, :aws_kms)

      reloaded = Repo.one!(from(u in User, where: u.id == ^user.id), skip_tenant_check: true)

      assert <<0xAA, 0x01, _ct::binary>> = reloaded.encrypted_dek
      assert reloaded.encrypted_dek != original_blob
      assert reloaded.key_provider == "aws_kms"
      assert reloaded.dek_version == Engram.Crypto.Config.master_key_version()
    end
  end
end
