ExUnit.start(assert_receive_timeout: 2_000)
Ecto.Adapters.SQL.Sandbox.mode(Engram.Repo, :manual)

# Capture log output during tests. Logger messages are buffered per-test and
# only re-emitted to stdout when that test FAILS — green tests stay silent.
# This hides intentional-error-path noise (e.g. `vault decrypt_failed`
# reason=:no_dek from test factories that skip DEK provisioning) while
# preserving full diagnostic output for real failures.
ExUnit.configure(capture_log: true)

# Infra-dependent tags excluded by default; opt in via env var.
# - :qdrant_integration needs a running Qdrant (CI stack) → QDRANT_INTEGRATION=1
# - :cluster needs BEAM distribution (epmd + longnames). CI's unit-tests runner
#   has no distribution (:net_kernel.start fails with :nodistribution), so these
#   real two-node :peer tests are opt-in → CLUSTER_TESTS=1 (run locally, or in a
#   dedicated CI job that provides distribution).
# - :integration needs a local engram-dev-postgres docker container to drive
#   pg_dump from. CI runs against an ephemeral PG service (no docker exec
#   target), so these are opt-in → INTEGRATION_TESTS=1 (run locally).
qdrant_excluded =
  if System.get_env("QDRANT_INTEGRATION") == "1", do: [], else: [:qdrant_integration]

cluster_excluded = if System.get_env("CLUSTER_TESTS") == "1", do: [], else: [:cluster]

integration_excluded =
  if System.get_env("INTEGRATION_TESTS") == "1", do: [], else: [:integration]

case qdrant_excluded ++ cluster_excluded ++ integration_excluded do
  [] -> :ok
  excluded -> ExUnit.configure(exclude: excluded)
end

# Ensure SPA index.html has </head> for config injection.
# CI has no frontend build → write a minimal stub.
# Real build (detected by `id="root"`) missing </head> = error, not overwrite:
# the minifier shouldn't strip </head>, so this would be a genuine build bug.
spa_dir = Application.app_dir(:engram, "priv/static/app")
File.mkdir_p!(spa_dir)
index_path = Path.join(spa_dir, "index.html")

case File.read(index_path) do
  {:ok, html} ->
    cond do
      String.contains?(html, "</head>") ->
        :ok

      String.contains?(html, ~s(id="root")) ->
        raise """
        Real SPA build at #{index_path} is missing </head>.
        Refusing to overwrite. Rebuild the frontend or delete the file.
        """

      true ->
        File.write!(
          index_path,
          ~s(<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>)
        )
    end

  {:error, _} ->
    File.write!(
      index_path,
      ~s(<!DOCTYPE html><html><head></head><body><div id="root"></div></body></html>)
    )
end
