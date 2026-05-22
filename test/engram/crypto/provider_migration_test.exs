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

  defp attach_telemetry_capture(test_pid) do
    handler_id = "test-migrate-provider-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:engram, :crypto, :migrate_provider, :user],
      fn _name, measurements, metadata, _cfg ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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

  describe "migrate_user/2 KMS→Local reverse" do
    test "rewraps from KMS blob back to Local with 0x01/0x02 leading byte" do
      stub_kms_roundtrip()
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)
      user = insert(:user)
      {:ok, user} = Crypto.ensure_user_dek(user)
      assert <<0xAA, _::binary>> = user.encrypted_dek

      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
      assert :ok = ProviderMigration.migrate_user(user.id, :local)

      reloaded = Repo.one!(from(x in User, where: x.id == ^user.id), skip_tenant_check: true)
      assert <<tag, 0x01, _::binary-size(60)>> = reloaded.encrypted_dek
      assert tag in [0x01, 0x02]
      assert reloaded.key_provider == "local"
    end
  end

  describe "migrate_user/2 idempotence" do
    test "returns :skipped when user is already at target_provider, no provider calls made" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()

      # First migration: Local→KMS.
      assert :ok = ProviderMigration.migrate_user(user.id, :aws_kms)

      # Second migration to same target: skipped, zero KMS calls expected
      # because the cond branch short-circuits before touching providers.
      expect(Engram.AwsKmsMock, :encrypt, 0, fn _, _ -> :unused end)
      expect(Engram.AwsKmsMock, :decrypt, 0, fn _, _ -> :unused end)

      assert :skipped = ProviderMigration.migrate_user(user.id, :aws_kms)
    end
  end

  describe "migrate_user/2 failure modes" do
    test ":kms_access_denied surfaces, txn rolls back, blob unchanged, telemetry :failed" do
      Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)
      stub(Engram.AwsKmsMock, :encrypt, fn _, _ -> {:error, :access_denied} end)

      user = user_with_local_dek!()
      original_blob = user.encrypted_dek

      attach_telemetry_capture(self())

      assert {:error, {:kms_encrypt_failed, :access_denied}} =
               ProviderMigration.migrate_user(user.id, :aws_kms)

      reloaded = Repo.one!(from(u in User, where: u.id == ^user.id), skip_tenant_check: true)
      assert reloaded.encrypted_dek == original_blob
      assert reloaded.key_provider == "local"

      assert_receive {:telemetry, %{count: 1},
                      %{status: :failed, reason_label: "kms_encrypt_failed"}}
    end

    test ":kms_throttled surfaces verbatim" do
      stub(Engram.AwsKmsMock, :encrypt, fn _, _ -> {:error, :throttled} end)

      user = user_with_local_dek!()

      assert {:error, {:kms_encrypt_failed, :throttled}} =
               ProviderMigration.migrate_user(user.id, :aws_kms)
    end

    test "user deleted mid-flight returns {:error, {:not_found, uid}}" do
      stub_kms_roundtrip()
      missing_id = 99_999_999

      assert {:error, {:not_found, ^missing_id}} =
               ProviderMigration.migrate_user(missing_id, :aws_kms)
    end

    test "user with nil encrypted_dek returns {:error, :no_dek}" do
      stub_kms_roundtrip()
      user = insert(:user)
      # Sanity: factory does not auto-provision a wrapped DEK.
      assert is_nil(user.encrypted_dek)

      assert {:error, :no_dek} = ProviderMigration.migrate_user(user.id, :aws_kms)
    end

    test "happy path emits :ok telemetry with target_provider metadata" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()

      attach_telemetry_capture(self())

      assert :ok = ProviderMigration.migrate_user(user.id, :aws_kms)

      assert_receive {:telemetry, %{count: 1, duration_us: dur},
                      %{user_id: uid, target_provider: :aws_kms, status: :ok}}
                     when is_integer(dur) and dur >= 0

      assert uid == user.id
    end
  end

  describe "migrate_user/2 concurrent races" do
    test "4 parallel migrate_user calls for same user → exactly one rewrap, three :skipped" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()
      uid = user.id
      parent = self()

      results =
        1..4
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, parent, self())
            ProviderMigration.migrate_user(uid, :aws_kms)
          end,
          max_concurrency: 4,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      ok_count = Enum.count(results, &(&1 == :ok))
      skipped_count = Enum.count(results, &(&1 == :skipped))

      assert ok_count == 1,
             "expected exactly one :ok, got #{ok_count} (results=#{inspect(results)})"

      assert skipped_count == 3, "expected three :skipped, got #{skipped_count}"

      reloaded = Repo.one!(from(u in User, where: u.id == ^uid), skip_tenant_check: true)
      assert reloaded.key_provider == "aws_kms"
    end
  end

  describe "migrate_all/2" do
    test "drains every user not at target into the target provider" do
      stub_kms_roundtrip()
      u1 = user_with_local_dek!()
      u2 = user_with_local_dek!()

      # u3 starts on KMS — must be skipped.
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)
      u3 = insert(:user)
      {:ok, _} = Crypto.ensure_user_dek(u3)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

      assert %{ok: ok_count, skipped: skipped_count, failed: 0} =
               ProviderMigration.migrate_all(:aws_kms, batch_size: 10)

      # u1 + u2 should rewrap.
      assert ok_count >= 2

      # u3 contributes to :skipped. Other already-aws_kms users from prior
      # tests in this DB sandbox may also contribute.
      assert skipped_count >= 1

      assert "aws_kms" =
               Repo.one!(from(u in User, where: u.id == ^u1.id, select: u.key_provider),
                 skip_tenant_check: true
               )

      assert "aws_kms" =
               Repo.one!(from(u in User, where: u.id == ^u2.id, select: u.key_provider),
                 skip_tenant_check: true
               )
    end
  end

  describe "enqueue_all/2" do
    test "inserts one Oban job per below-target user" do
      _u1 = user_with_local_dek!()
      _u2 = user_with_local_dek!()

      assert %{enqueued: n} = ProviderMigration.enqueue_all(:aws_kms, batch_size: 10)
      assert n >= 2

      jobs =
        Oban.Job
        |> Repo.all(skip_tenant_check: true)
        |> Enum.filter(&(&1.worker == "Engram.Workers.MigrateUserProvider"))

      assert length(jobs) >= 2

      Enum.each(jobs, fn job ->
        assert %{"target_provider" => "aws_kms", "user_id" => uid} = job.args
        assert is_integer(uid)
      end)
    end
  end

  describe "status_counts/0" do
    test "returns counts grouped by users.key_provider" do
      _ = user_with_local_dek!()
      counts = ProviderMigration.status_counts()
      assert is_map(counts)
      assert counts[:local] >= 1
      assert Map.has_key?(counts, :total)
      assert counts.total == (counts[:local] || 0) + (counts[:aws_kms] || 0)
    end
  end
end
