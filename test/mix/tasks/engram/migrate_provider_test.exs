defmodule Mix.Tasks.Engram.MigrateProviderTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox
  import ExUnit.CaptureIO
  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Mix.Tasks.Engram.MigrateProvider

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
      Application.put_env(:engram, :aws_kms_client, prev_client)

      if prev_provider do
        Application.put_env(:engram, :key_provider, prev_provider)
      else
        Application.delete_env(:engram, :key_provider)
      end
    end)

    table = :ets.new(:task_kms_stub, [:set, :public])

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

  defp local_user! do
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    user
  end

  describe "run/1 — sync drain" do
    test "--target aws_kms rewraps every local user" do
      _u1 = local_user!()
      _u2 = local_user!()

      out =
        capture_io(fn ->
          MigrateProvider.run(["--target", "aws_kms"])
        end)

      assert out =~ "migration complete"
      assert out =~ "ok="
    end
  end

  describe "run/1 — enqueue" do
    test "--target aws_kms --enqueue inserts jobs without performing rewraps" do
      user = local_user!()

      out =
        capture_io(fn ->
          MigrateProvider.run(["--target", "aws_kms", "--enqueue"])
        end)

      assert out =~ "enqueued"
      assert_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})

      reloaded =
        Engram.Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id),
          skip_tenant_check: true
        )

      # Not rewrapped yet — only enqueued.
      assert reloaded.key_provider == "local"
    end
  end

  describe "run/1 — status" do
    test "--status prints provider counts" do
      _ = local_user!()

      out =
        capture_io(fn ->
          MigrateProvider.run(["--status"])
        end)

      assert out =~ "local="
      assert out =~ "aws_kms="
      assert out =~ "total="
    end
  end

  describe "run/1 — argument validation" do
    test "unknown --target exits 2" do
      exit_result =
        catch_exit(
          capture_io(:stderr, fn ->
            MigrateProvider.run(["--target", "passphrase"])
          end)
        )

      assert exit_result == {:shutdown, 2}
    end

    test "missing required --target without --status exits 2" do
      exit_result =
        catch_exit(
          capture_io(:stderr, fn ->
            MigrateProvider.run([])
          end)
        )

      assert exit_result == {:shutdown, 2}
    end
  end
end
