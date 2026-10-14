defmodule Engram.Workers.LegalNoticeEmailTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Email.Suppression
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Workers.LegalNoticeEmail

  setup :verify_on_exit!

  setup do
    prev_provider = Application.get_env(:engram, :email_provider)
    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)

    on_exit(fn ->
      if is_nil(prev_provider),
        do: Application.delete_env(:engram, :email_provider),
        else: Application.put_env(:engram, :email_provider, prev_provider)

      LegalFixtures.reset_version_cache()
    end)

    LegalFixtures.insert_version(version: "2026-05-19")
    LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")

    LegalFixtures.insert_version(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: ~D[2099-11-11],
      changelog: "Analytics <now> linked to your account."
    )

    LegalFixtures.reset_version_cache()
    %{user: insert(:user, email: "u@example.com")}
  end

  defp args(user, kind \\ "notice"),
    do: %{
      "user_id" => user.id,
      "document" => "privacy_policy",
      "version" => "2026-10-12",
      "kind" => kind
    }

  test "emails the change, its effective date and the policy link", %{user: user} do
    expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
      assert to == "u@example.com"
      assert subject == "We updated Engram's Privacy Policy"
      assert html =~ "November 11, 2099"
      assert html =~ "Analytics &lt;now&gt; linked to your account."
      assert html =~ "https://engram.page/privacy"
      :ok
    end)

    assert :ok = perform_job(LegalNoticeEmail, args(user))
  end

  test "a reminder says so in the subject", %{user: user} do
    expect(Engram.Email.ProviderMock, :send, fn _to, subject, _html, _opts ->
      assert subject == "Reminder: Engram's Privacy Policy changes on November 11, 2099"
      :ok
    end)

    assert :ok = perform_job(LegalNoticeEmail, args(user, "reminder"))
  end

  test "skips a user who already accepted the version", %{user: user} do
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-19", "h", "2026-10-12", "h", %{})
    expect(Engram.Email.ProviderMock, :send, 0, fn _, _, _, _ -> :ok end)
    assert :ok = perform_job(LegalNoticeEmail, args(user))
  end

  test "skips a deleted user" do
    user = insert(:user, deleted_at: DateTime.utc_now())
    expect(Engram.Email.ProviderMock, :send, 0, fn _, _, _, _ -> :ok end)
    assert :ok = perform_job(LegalNoticeEmail, args(user))
  end

  test "a suppressed address is not retried", %{user: user} do
    {:ok, _} = Suppression.suppress("u@example.com", :bounced)
    expect(Engram.Email.ProviderMock, :send, 0, fn _, _, _, _ -> :ok end)
    assert :ok = perform_job(LegalNoticeEmail, args(user))
  end

  test "a provider failure is returned so Oban retries", %{user: user} do
    expect(Engram.Email.ProviderMock, :send, fn _, _, _, _ -> {:error, :rate_limited} end)
    assert {:error, :rate_limited} = perform_job(LegalNoticeEmail, args(user))
  end

  test "enqueueing the same user, version and kind twice keeps one job", %{user: user} do
    {:ok, _} = args(user) |> LegalNoticeEmail.new() |> Oban.insert()
    {:ok, dup} = args(user) |> LegalNoticeEmail.new() |> Oban.insert()
    assert dup.conflict?
  end
end
