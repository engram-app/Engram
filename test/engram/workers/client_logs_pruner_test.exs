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
          # Minted when the row was written, as the column default does.
          id: UUIDv7.generate(DateTime.to_unix(ts, :millisecond)),
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

  # created_at is the correctness bound: an id older than its created_at
  # (clock skew between app and DB) must not get a young row deleted.
  test "never deletes a row younger than retention, whatever its id", %{user: user} do
    Application.put_env(:engram, :client_logs_retention_days, 30)
    now = DateTime.utc_now(:second)
    old_ms = now |> DateTime.add(-40 * 24 * 3600, :second) |> DateTime.to_unix(:millisecond)

    {1, _} =
      Repo.insert_all(ClientLog, [
        %{
          id: UUIDv7.generate(old_ms),
          user_id: user.id,
          ts: now,
          message: "x",
          created_at: now
        }
      ])

    assert {:ok, 0} = perform_job(ClientLogsPruner, %{})
    assert count() == 1
  end

  test "the batch query walks the primary key" do
    cutoff = NaiveDateTime.utc_now()
    floor = ClientLogsPruner.id_floor(System.system_time(:millisecond))

    {sql, _} =
      Repo.to_sql(
        :all,
        from(s in "client_logs",
          where: s.id < type(^floor, Ecto.UUID) and s.created_at < ^cutoff,
          order_by: s.id,
          select: s.id,
          limit: 5000
        )
      )

    assert Engram.QueryPlan.generic_plan(sql) =~ "client_logs_pkey"
  end

  test "id_floor/1 sorts below every uuidv7 minted at or after that millisecond" do
    ms = System.system_time(:millisecond)
    floor = ClientLogsPruner.id_floor(ms)

    assert UUIDv7.generate(ms) >= floor
    assert UUIDv7.generate(ms - 1) < floor
  end

  test "is a no-op when nothing is past retention", %{user: user} do
    Application.put_env(:engram, :client_logs_retention_days, 30)
    insert_log(user, 1)

    assert {:ok, 0} = perform_job(ClientLogsPruner, %{})
    assert count() == 1
  end
end
