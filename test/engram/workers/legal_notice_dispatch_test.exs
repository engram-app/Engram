defmodule Engram.Workers.LegalNoticeDispatchTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Legal.TermsVersion
  alias Engram.LegalFixtures
  alias Engram.Workers.LegalNoticeDispatch
  alias Engram.Workers.LegalNoticeEmail

  defp version(attrs), do: LegalFixtures.insert_version(attrs)
  defp reload(row), do: Repo.get!(TermsVersion, row.id, skip_tenant_check: true)
  defp days(n), do: Date.add(Date.utc_today(), n)

  defp email_jobs do
    all_enqueued(worker: LegalNoticeEmail)
    |> Enum.map(&{&1.args["user_id"], &1.args["kind"], &1.args["version"]})
    |> Enum.sort()
  end

  setup do
    live = insert(:user)
    _deleted = insert(:user, deleted_at: DateTime.utc_now())
    %{live: live}
  end

  test "emails every live user once about a future-dated version", %{live: live} do
    row =
      version(
        document: "privacy_policy",
        version: "2026-10-12",
        material: false,
        effective_date: days(29)
      )

    assert :ok = perform_job(LegalNoticeDispatch, %{})
    assert email_jobs() == [{live.id, "notice", "2026-10-12"}]
    assert reload(row).notified_at

    assert :ok = perform_job(LegalNoticeDispatch, %{})
    assert length(all_enqueued(worker: LegalNoticeEmail)) == 1
  end

  test "ignores versions effective now, in the past, or with no date" do
    for {v, date} <- [{"2026-05-19", nil}, {"2026-06-01", days(-1)}, {"2026-07-01", days(0)}],
        do: version(version: v, effective_date: date)

    assert :ok = perform_job(LegalNoticeDispatch, %{})
    assert email_jobs() == []
  end

  test "reminds about a material change in its last 7 days", %{live: live} do
    row =
      version(version: "2026-10-12", material: true, effective_date: days(6))
      |> Ecto.Changeset.change(notified_at: DateTime.add(DateTime.utc_now(), -25, :day))
      |> Repo.update!(skip_tenant_check: true)

    assert :ok = perform_job(LegalNoticeDispatch, %{})
    assert email_jobs() == [{live.id, "reminder", "2026-10-12"}]
    assert reload(row).reminded_at

    assert :ok = perform_job(LegalNoticeDispatch, %{})
    assert length(all_enqueued(worker: LegalNoticeEmail)) == 1
  end

  test "no reminder for a notice-only change" do
    version(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: days(6)
    )
    |> Ecto.Changeset.change(notified_at: DateTime.add(DateTime.utc_now(), -25, :day))
    |> Repo.update!(skip_tenant_check: true)

    assert :ok = perform_job(LegalNoticeDispatch, %{})
    assert email_jobs() == []
  end

  test "a version first noticed inside the reminder window gets the notice only", %{live: live} do
    version(version: "2026-10-12", material: true, effective_date: days(5))

    assert :ok = perform_job(LegalNoticeDispatch, %{})
    assert email_jobs() == [{live.id, "notice", "2026-10-12"}]
  end
end
