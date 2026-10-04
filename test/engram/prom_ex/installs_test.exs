defmodule Engram.PromEx.InstallsTest do
  use Engram.DataCase, async: false

  alias Engram.PromEx.Installs, as: Plugin
  alias Engram.Repo
  alias Engram.Telemetry.InstallPing

  @event [:engram, :installs, :seen]

  setup do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)

    ref = make_ref()
    test_pid = self()
    handler = "installs-test-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      @event,
      fn _e, %{count: count}, meta, _ -> send(test_pid, {:seen, meta, count}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp ping!(os, arch, runtime, days_ago) do
    at = DateTime.utc_now(:second) |> DateTime.add(-days_ago * 86_400)

    Repo.insert!(
      %InstallPing{
        id: Ecto.UUID.generate(),
        version: "0.5.518",
        os: os,
        arch: arch,
        runtime: runtime,
        inserted_at: at,
        updated_at: at
      },
      skip_tenant_check: true
    )
  end

  defp collect(acc \\ %{}) do
    receive do
      {:seen, meta, count} -> collect(Map.put(acc, {meta.os, meta.arch, meta.runtime}, count))
    after
      100 -> acc
    end
  end

  test "counts installs seen in the last 30 days per os/arch/runtime" do
    ping!("linux", "amd64", "docker", 0)
    ping!("linux", "amd64", "docker", 29)
    ping!("darwin", "arm64", "source", 1)

    seen = Plugin.execute_install_metrics() && collect()

    assert seen[{"linux", "amd64", "docker"}] == 2
    assert seen[{"darwin", "arm64", "source"}] == 1
  end

  test "an install that has gone quiet for over 30 days drops out" do
    ping!("linux", "amd64", "docker", 31)

    assert collect(Plugin.execute_install_metrics() && %{})[{"linux", "amd64", "docker"}] == 0
  end

  test "emits every combination, zeros included, so a vanished group never goes stale" do
    Plugin.execute_install_metrics()
    seen = collect()

    assert map_size(seen) == 4 * 3 * 2
    assert Enum.all?(Map.values(seen), &(&1 == 0))
  end

  test "emits nothing on self-host (billing disabled): the table is the SaaS collector's" do
    Application.put_env(:engram, :billing_enabled, false)
    ping!("linux", "amd64", "docker", 0)

    Plugin.execute_install_metrics()
    assert collect() == %{}
  end

  test "a poll before Engram.Repo has started returns :ok instead of raising" do
    # Prod bug: the first poll runs at boot before Engram.Repo is up and raised
    # "could not lookup Ecto repo Engram.Repo because it was not started or it
    # does not exist". telemetry_poller then removed this measurement for good,
    # so the gauge never populated until the next restart. Pointing this process
    # at a repo name that was never started reproduces that exact error without
    # touching the sandbox connection.
    Repo.put_dynamic_repo(:census_repo_that_was_never_started)
    on_exit(fn -> Repo.put_dynamic_repo(Repo) end)

    assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
      Repo.all(InstallPing, skip_tenant_check: true)
    end

    assert :ok = Plugin.execute_install_metrics()
    assert collect() == %{}
  end
end
