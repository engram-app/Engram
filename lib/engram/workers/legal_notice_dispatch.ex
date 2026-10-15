defmodule Engram.Workers.LegalNoticeDispatch do
  @moduledoc """
  Tells users about legal changes without anyone sending anything by hand.

  Hourly, it looks for two kinds of due work on `terms_versions`:

    * **Notice.** A version effective on a future date that has not been
      announced (`notified_at` nil): one `LegalNoticeEmail` per live user.
    * **Reminder.** A MATERIAL version in its last 7 days, announced before
      that window opened, not yet reminded: one `LegalNoticeEmail` per live
      user (the email job skips anyone who has accepted by then).

  Each kind is claimed by a conditional UPDATE in the same transaction that
  inserts the email jobs, so concurrent nodes or a retry never send twice and a
  crash never loses the send. Publishing a version is the whole procedure: add
  it to the seeder with a future `effective_date` and deploy.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Legal.TermsVersion
  alias Engram.Repo
  alias Engram.Workers.LegalNoticeEmail

  # skip_tenant_check, not Repo.maintenance(): `terms_versions` and `users`
  # carry no tenant policy, and the claim must share Oban's connection so it
  # commits or rolls back with the job inserts.
  @reminder_days 7
  @insert_chunk 1_000

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(_job) do
    today = Date.utc_today()
    # Both lists are read before either is claimed, so a version announced in
    # this run cannot also be reminded in it.
    due = Enum.map(Repo.all(notice_due(today), skip_tenant_check: true), &{:notified_at, &1})

    due =
      due ++ Enum.map(Repo.all(reminder_due(today), skip_tenant_check: true), &{:reminded_at, &1})

    Enum.each(due, fn {stamp, version} -> {:ok, _} = fan_out(stamp, version) end)
  end

  defp notice_due(today),
    do: from(v in TermsVersion, where: is_nil(v.notified_at) and v.effective_date > ^today)

  defp reminder_due(today) do
    from(v in TermsVersion,
      where: v.material and is_nil(v.reminded_at) and not is_nil(v.notified_at),
      where: v.effective_date > ^today and v.effective_date <= ^Date.add(today, @reminder_days),
      # Announced before the reminder window opened; a late notice is enough.
      where:
        fragment("(? AT TIME ZONE 'UTC')::date", v.notified_at) <
          date_add(v.effective_date, -@reminder_days, "day")
    )
  end

  defp fan_out(stamp, version) do
    kind = if stamp == :notified_at, do: "notice", else: "reminder"

    Repo.transaction(fn ->
      {claimed, _} =
        from(v in TermsVersion, where: v.id == ^version.id and is_nil(field(v, ^stamp)))
        |> Repo.update_all([set: [{stamp, DateTime.utc_now()}]], skip_tenant_check: true)

      if claimed == 1, do: enqueue_emails(version, kind)
    end)
  end

  # ponytail: every live user id in memory at once; stream if users pass ~1M.
  defp enqueue_emails(version, kind) do
    from(u in User, where: is_nil(u.deleted_at) and not is_nil(u.email), select: u.id)
    |> Repo.all(skip_tenant_check: true)
    |> Enum.map(
      &LegalNoticeEmail.new(%{
        "user_id" => &1,
        "document" => version.document,
        "version" => version.version,
        "kind" => kind
      })
    )
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(&oban().insert_all/1)
  end

  defp oban, do: Application.get_env(:engram, :oban_facade, Oban)
end
