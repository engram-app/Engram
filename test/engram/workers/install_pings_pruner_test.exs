defmodule Engram.Workers.InstallPingsPrunerTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Repo
  alias Engram.Telemetry.InstallPing
  alias Engram.Workers.InstallPingsPruner

  defp ping_row(days_ago) do
    at = DateTime.utc_now(:second) |> DateTime.add(-days_ago * 86_400)

    %{
      id: Ecto.UUID.generate(),
      version: "0.5.518",
      os: "linux",
      arch: "amd64",
      runtime: "docker",
      inserted_at: at,
      updated_at: at
    }
  end

  defp insert_pings(days_ago_list) do
    rows = Enum.map(days_ago_list, &ping_row/1)

    for chunk <- Enum.chunk_every(rows, 5_000) do
      Repo.insert_all(InstallPing, chunk, skip_tenant_check: true)
    end
  end

  defp count, do: Repo.aggregate(InstallPing, :count, :id, skip_tenant_check: true)

  test "deletes installs not seen for over 35 days and keeps the rest" do
    insert_pings([0, 30, 34, 36, 90])

    assert {:ok, 2} = perform_job(InstallPingsPruner, %{})
    assert count() == 3
  end

  test "keeps everything the 30-day gauge window can still see" do
    insert_pings([0, 29, 30])

    assert {:ok, 0} = perform_job(InstallPingsPruner, %{})
    assert count() == 3
  end

  test "is a no-op on an empty table" do
    assert {:ok, 0} = perform_job(InstallPingsPruner, %{})
  end

  test "keeps deleting across batch boundaries" do
    insert_pings([0 | List.duplicate(60, 5_001)])

    assert {:ok, 5_001} = perform_job(InstallPingsPruner, %{})
    assert count() == 1
  end
end
