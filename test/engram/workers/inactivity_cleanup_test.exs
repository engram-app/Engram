defmodule Engram.Workers.InactivityCleanupTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Mox

  alias Engram.Accounts
  alias Engram.Repo
  alias Engram.Storage.InMemory
  alias Engram.UsageMeters
  alias Engram.UsageMeters.Meter
  alias Engram.Workers.InactivityCleanup

  setup :verify_on_exit!

  setup do
    InMemory.ensure_table()

    prev_provider = Application.get_env(:engram, :email_provider)
    prev_storage = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)
    Application.put_env(:engram, :storage, InMemory)

    on_exit(fn ->
      if is_nil(prev_provider),
        do: Application.delete_env(:engram, :email_provider),
        else: Application.put_env(:engram, :email_provider, prev_provider)

      if is_nil(prev_storage),
        do: Application.delete_env(:engram, :storage),
        else: Application.put_env(:engram, :storage, prev_storage)
    end)

    :ok
  end

  defp set_last_active(user_id, days_ago) do
    ts = DateTime.utc_now() |> DateTime.add(-days_ago * 86_400, :second)
    UsageMeters.bump_last_active(user_id)

    Engram.Repo.update_all(
      from(m in Meter, where: m.user_id == ^user_id),
      [set: [last_active_at: ts]],
      skip_tenant_check: true
    )
  end

  describe "60-day warning sweep" do
    test "sends warning #1 + stamps timestamp for Free user inactive 60-79 days" do
      user = insert(:user)
      set_last_active(user.id, 65)

      expect(Engram.Email.ProviderMock, :send, fn to, subject, _html, _opts ->
        assert to == user.email
        assert subject =~ "60 days"
        :ok
      end)

      InactivityCleanup.__sweep_60__()

      reloaded = Accounts.get_user!(user.id)
      assert %DateTime{} = reloaded.inactivity_warning_60_at
    end

    test "does not re-send when warning already stamped" do
      user = insert(:user, inactivity_warning_60_at: DateTime.utc_now())
      set_last_active(user.id, 65)

      # No expect — Mox would fail if send/4 is called
      InactivityCleanup.__sweep_60__()
    end

    test "skips users inactive < 60 days" do
      user = insert(:user)
      set_last_active(user.id, 30)
      InactivityCleanup.__sweep_60__()

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.inactivity_warning_60_at)
    end
  end

  describe "80-day warning sweep" do
    test "sends final notice for Free user inactive 80-89 days" do
      user = insert(:user)
      set_last_active(user.id, 85)

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, _html, _opts ->
        assert subject =~ "final notice"
        :ok
      end)

      InactivityCleanup.__sweep_80__()

      reloaded = Accounts.get_user!(user.id)
      assert %DateTime{} = reloaded.inactivity_warning_80_at
    end
  end

  describe "90-day soft-delete sweep" do
    test "drops Qdrant + stamps users.deleted_at + emails the user" do
      user = insert(:user)
      set_last_active(user.id, 95)

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, _html, _opts ->
        assert subject =~ "auto-deleted"
        :ok
      end)

      # Qdrant call goes to live HTTP; in tests we run without a Qdrant URL,
      # which causes the call to fail. The worker catches that as best-effort.
      InactivityCleanup.__sweep_soft__()

      reloaded = Accounts.get_user!(user.id)
      assert %DateTime{} = reloaded.deleted_at
    end

    test "skips users with active subscription (paid tier exempt)" do
      user = insert(:user)
      set_last_active(user.id, 95)

      insert(:subscription, user: user, tier: "starter", status: "active")

      # No expect — paid tier should not be touched
      InactivityCleanup.__sweep_soft__()

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.deleted_at)
    end
  end

  describe "hard-delete sweep" do
    test "wipes user row + S3 prefix when soft-deleted >30 days ago" do
      user = insert(:user)
      thirty_one_days_ago = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second)

      InMemory.put("#{user.id}/vault1/file.png", "binary")

      user
      |> Ecto.Changeset.change(%{deleted_at: thirty_one_days_ago})
      |> Repo.update!(skip_tenant_check: true)

      InactivityCleanup.__sweep_hard__()

      assert {:error, :user_not_found} = Accounts.find_by_external_id(user.external_id || "")
      assert is_nil(Accounts.get_user(user.id))

      refute InMemory.exists?("#{user.id}/vault1/file.png")
    end

    test "cascades the usage_meters row (notes_count counter) on hard-delete" do
      # The notes_count counter relies on the meter row vanishing with the user
      # rather than an explicit decrement. Pin that FK cascade so a future
      # on_delete change can't silently strand the counter.
      user = insert(:user)
      Repo.insert!(%Meter{user_id: user.id, notes_count: 5})
      assert UsageMeters.notes_count(user.id) == 5

      thirty_one_days_ago = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second)

      user
      |> Ecto.Changeset.change(%{deleted_at: thirty_one_days_ago})
      |> Repo.update!(skip_tenant_check: true)

      InactivityCleanup.__sweep_hard__()

      refute Repo.get(Meter, user.id, skip_tenant_check: true)
    end

    test "leaves soft-deleted users <30 days alone" do
      user = insert(:user)
      ten_days_ago = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second)

      user
      |> Ecto.Changeset.change(%{deleted_at: ten_days_ago})
      |> Repo.update!(skip_tenant_check: true)

      InactivityCleanup.__sweep_hard__()

      refute is_nil(Accounts.get_user(user.id))
    end
  end

  describe "per-user limit overrides" do
    test "inactivity_warn_60_days=false override suppresses 60-day warning" do
      user = insert(:user)
      set_last_active(user.id, 65)

      insert(:user_limit_override,
        user: user,
        key: "inactivity_warn_60_days",
        value: %{"v" => false}
      )

      # No Mox expect — send/4 must not be called.
      InactivityCleanup.__sweep_60__()

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.inactivity_warning_60_at)
    end

    test "inactivity_warn_60_days=false override suppresses 80-day warning" do
      user = insert(:user)
      set_last_active(user.id, 85)

      insert(:user_limit_override,
        user: user,
        key: "inactivity_warn_60_days",
        value: %{"v" => false}
      )

      InactivityCleanup.__sweep_80__()

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.inactivity_warning_80_at)
    end

    test "inactivity_delete_days=180 override defers soft-delete past Free default" do
      user = insert(:user)
      set_last_active(user.id, 95)

      insert(:user_limit_override,
        user: user,
        key: "inactivity_delete_days",
        value: %{"v" => 180}
      )

      InactivityCleanup.__sweep_soft__()

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.deleted_at)
    end

    test "inactivity_delete_days=60 override soft-deletes earlier than Free default" do
      user = insert(:user)
      set_last_active(user.id, 65)

      insert(:user_limit_override,
        user: user,
        key: "inactivity_delete_days",
        value: %{"v" => 60}
      )

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, _html, _opts -> :ok end)

      InactivityCleanup.__sweep_soft__()

      reloaded = Accounts.get_user!(user.id)
      assert %DateTime{} = reloaded.deleted_at
    end
  end

  describe "after Lifecycle refactor" do
    test "sweep_soft_delete fires :account telemetry with :inactivity reason" do
      user = insert(:user)
      set_last_active(user.id, 95)

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, _html, _opts -> :ok end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :account, :soft_deleted]
        ])

      InactivityCleanup.__sweep_soft__()

      assert_receive {[:engram, :account, :soft_deleted], ^ref, _, %{reason: :inactivity}}
    end

    test "sweep_hard_delete fires :account telemetry with :inactivity reason" do
      user = insert(:user)
      thirty_one_days_ago = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second)

      user
      |> Ecto.Changeset.change(%{deleted_at: thirty_one_days_ago})
      |> Repo.update!(skip_tenant_check: true)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :account, :deleted]
        ])

      InactivityCleanup.__sweep_hard__()

      assert_receive {[:engram, :account, :deleted], ^ref, _, %{reason: :inactivity}}
    end

    test "legacy :abuse telemetry still fires alongside" do
      user = insert(:user)
      set_last_active(user.id, 95)

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, _html, _opts -> :ok end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :abuse, :inactivity_soft_delete]
        ])

      InactivityCleanup.__sweep_soft__()

      assert_receive {[:engram, :abuse, :inactivity_soft_delete], ^ref, _, _}
    end
  end
end
