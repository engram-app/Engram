defmodule Engram.Workers.ClientLogsPrunerTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  import Engram.Factory
  import Ecto.Query

  alias Engram.Logs.ClientLog
  alias Engram.Repo
  alias Engram.Workers.ClientLogsPruner

  defp insert_log(user, days_ago) do
    ts =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 24 * 3600, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      Repo.insert_all(ClientLog, [
        %{
          user_id: user.id,
          ts: ts,
          level: "info",
          category: "",
          message: "x",
          plugin_version: "",
          platform: "",
          created_at: ts
        }
      ])
  end

  defp count, do: Repo.one(from(l in "client_logs", select: count(l.id)))

  setup do
    prev = Application.get_env(:engram, :client_logs_retention_days)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :client_logs_retention_days),
        else: Application.put_env(:engram, :client_logs_retention_days, prev)
    end)

    %{user: insert_user()}
  end

  test "deletes logs older than the retention window, keeps recent ones", %{user: user} do
    Application.put_env(:engram, :client_logs_retention_days, 30)
    insert_log(user, 40)
    insert_log(user, 5)
    assert count() == 2

    assert {:ok, 1} = perform_job(ClientLogsPruner, %{})

    assert count() == 1
  end

  test "honors a custom retention window", %{user: user} do
    Application.put_env(:engram, :client_logs_retention_days, 10)
    insert_log(user, 15)
    insert_log(user, 3)

    assert {:ok, 1} = perform_job(ClientLogsPruner, %{})
    assert count() == 1
  end

  test "is a no-op when nothing is past retention", %{user: user} do
    Application.put_env(:engram, :client_logs_retention_days, 30)
    insert_log(user, 1)

    assert {:ok, 0} = perform_job(ClientLogsPruner, %{})
    assert count() == 1
  end
end
