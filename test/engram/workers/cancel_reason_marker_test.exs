defmodule Engram.Workers.CancelReasonMarkerTest do
  # async: false: flips the app-wide :analytics_event_log flag.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Analytics.Event
  alias Engram.Analytics.EventLog
  alias Engram.Workers.CancelReasonMarker

  setup do
    prior = Application.get_env(:engram, :analytics_event_log)
    Application.put_env(:engram, :analytics_event_log, true)
    on_exit(fn -> Application.put_env(:engram, :analytics_event_log, prior) end)
    {:ok, user: insert(:user)}
  end

  defp args(user, scheduled_seconds_ago \\ 600) do
    now = DateTime.utc_now()

    %{
      "user_id" => user.id,
      "started_at" => now |> DateTime.add(-30 * 86_400) |> DateTime.to_iso8601(),
      "scheduled_at" => now |> DateTime.add(-scheduled_seconds_ago) |> DateTime.to_iso8601(),
      "effective_at" => "2027-10-01T00:00:00Z"
    }
  end

  defp log_event(user, event, props, seconds_ago) do
    Repo.insert!(%Event{
      user_id: user.id,
      event: event,
      props: props,
      inserted_at: DateTime.add(DateTime.utc_now(), -seconds_ago)
    })
  end

  defp reasons(user) do
    :ok = EventLog.flush()

    Repo.all(
      from(e in Event,
        where: e.user_id == ^user.id and e.event == "subscription_cancel_reason",
        select: e.props["reason"]
      )
    )
  end

  test "files portal_no_reason for a scheduled cancel the dialog never explained",
       %{user: user} do
    assert :ok = perform_job(CancelReasonMarker, args(user))
    assert reasons(user) == ["portal_no_reason"]
  end

  test "files nothing when the dialog's reason is on file", %{user: user} do
    log_event(user, "subscription_cancel_reason", %{"reason" => "not_using"}, 590)

    assert :ok = perform_job(CancelReasonMarker, args(user))
    assert reasons(user) == ["not_using"]
  end

  test "files nothing when the cancel was undone before the check ran", %{user: user} do
    log_event(user, "subscription_changed", %{"kind" => "cancel_reversed"}, 60)

    assert :ok = perform_job(CancelReasonMarker, args(user))
    assert reasons(user) == []
  end

  test "the canceled webhook does not file a second marker after this one",
       %{user: user} do
    assert :ok = perform_job(CancelReasonMarker, args(user))
    :ok = EventLog.flush()
    started = DateTime.add(DateTime.utc_now(), -30 * 86_400)

    assert :ok =
             Engram.Feedback.record_missing_cancel_reason(user, started, "portal_no_reason")

    assert reasons(user) == ["portal_no_reason"]
  end

  # Undo then re-cancel inside the unique window: the re-cancel must get its
  # own check, not be dropped as a duplicate of the first schedule.
  test "a re-schedule replaces the pending check with the newest one", %{user: user} do
    started = DateTime.add(DateTime.utc_now(), -30 * 86_400)
    first = DateTime.add(DateTime.utc_now(), -300)
    second = DateTime.utc_now()

    {:ok, first_job} =
      Oban.insert(CancelReasonMarker.new_for(user.id, started, "2027-10-01T00:00:00Z", first))

    {:ok, _} =
      Oban.insert(CancelReasonMarker.new_for(user.id, started, "2027-10-01T00:00:00Z", second))

    assert [job] = all_enqueued(worker: CancelReasonMarker)
    assert job.args["scheduled_at"] == DateTime.to_iso8601(second)
    # The run time moved too: the check waits out the dialog after the NEW cancel.
    assert DateTime.compare(job.scheduled_at, first_job.scheduled_at) == :gt
  end

  # The first check is already due but no queue has run it yet: the re-cancel
  # still swaps in its args, but keeps the run time (moving it would run now).
  test "a re-schedule replaces the args of an already-due check", %{user: user} do
    started = DateTime.add(DateTime.utc_now(), -30 * 86_400)
    first = DateTime.add(DateTime.utc_now(), -900)
    second = DateTime.utc_now()
    due_at = DateTime.add(DateTime.utc_now(), -60)

    {:ok, first_job} =
      Oban.insert(CancelReasonMarker.new_for(user.id, started, "2027-10-01T00:00:00Z", first))

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^first_job.id),
        set: [state: "available", scheduled_at: due_at]
      )

    {:ok, _} =
      Oban.insert(CancelReasonMarker.new_for(user.id, started, "2027-10-01T00:00:00Z", second))

    assert [job] = all_enqueued(worker: CancelReasonMarker)
    assert job.id == first_job.id
    assert job.state == "available"
    assert job.args["scheduled_at"] == DateTime.to_iso8601(second)
    assert DateTime.compare(job.scheduled_at, due_at) == :eq
  end

  test "a deleted user files nothing" do
    assert :ok = perform_job(CancelReasonMarker, args(%{id: Ecto.UUID.generate()}))
  end
end
