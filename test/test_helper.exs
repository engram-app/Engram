ExUnit.start(assert_receive_timeout: 2_000)
Ecto.Adapters.SQL.Sandbox.mode(Engram.Repo, :manual)

# Own the per-process service-config override table on the long-lived suite
# runner so a finishing async test can't destroy a concurrent test's overrides.
# See Engram.ServiceConfig.
Engram.ServiceConfig.ensure_table()

# Same for the in-memory storage blobs: a test that created the table would
# take every other test's blobs with it when it exits.
Engram.Storage.InMemory.ensure_table()

# Hybrid-search stub: batch answers record points for the retrieve stub.
Engram.QdrantStub.init()

# One suite-wide structured-log capture handler; see Engram.Test.LogCapture.
Engram.Test.LogCapture.install()

# Capture log output during tests. Logger messages are buffered per-test and
# only re-emitted to stdout when that test FAILS — green tests stay silent.
# This hides intentional-error-path noise (e.g. `vault decrypt_failed`
# reason=:no_dek from test factories that skip DEK provisioning) while
# preserving full diagnostic output for real failures.
ExUnit.configure(capture_log: true)

# Preload every module, as prod's embedded-mode release does. Tests run in
# interactive mode, so a module's first use goes through the single code
# server. Under a loaded parallel suite that queue stalled >15 s, while the
# caller held a sandbox connection inside a transaction: DBConnection killed
# the connection and the whole partition cascaded (nightly 39117525505,
# first stuck call `Engram.Native.text_diff/2`; #1210 hit the same with the
# OpenAPI schema modules). Pay the load once here, outside any test.
for {app, _, _} <- Application.loaded_applications() do
  Code.ensure_all_loaded(Application.spec(app, :modules) || [])
end

_ = EngramWeb.ApiSpec.spec()

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

# `config/runtime.exs` reads QDRANT_URL only outside :test, so the integration
# tests would otherwise be stuck on the client's compiled-in default port. CI
# runs its Qdrant on an ephemeral port (same pattern as the postgres container),
# so honour the env var here when those tests are actually enabled.
if System.get_env("QDRANT_INTEGRATION") == "1" do
  if url = System.get_env("QDRANT_URL") do
    Application.put_env(:engram, :qdrant_url, url)
  end

  # Preflight, so an unreachable Qdrant says WHICH url it tried instead of
  # surfacing as a bare econnrefused inside every test's setup block.
  resolved = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")

  case Req.get(resolved <> "/healthz", retry: false, receive_timeout: 5_000) do
    {:ok, %{status: 200}} ->
      IO.puts("qdrant_integration: #{resolved} reachable")

    other ->
      IO.warn("""
      QDRANT_INTEGRATION=1 but #{resolved} is not answering /healthz: #{inspect(other)}
      Every :qdrant_integration test will fail in setup. Check QDRANT_URL and that
      the container is still running.
      """)
  end
end

cluster_excluded = if System.get_env("CLUSTER_TESTS") == "1", do: [], else: [:cluster]

integration_excluded =
  if System.get_env("INTEGRATION_TESTS") == "1", do: [], else: [:integration]

# - :vendor_conformance makes real outbound HTTPS requests to third-party
#   vendors (ChatGPT et al) to check their published CIMD documents are still
#   ones we accept. Excluded by default so a vendor's outage can never block a
#   merge; it runs on a schedule instead → VENDOR_CONFORMANCE=1.
vendor_conformance_excluded =
  if System.get_env("VENDOR_CONFORMANCE") == "1", do: [], else: [:vendor_conformance]

case qdrant_excluded ++
       cluster_excluded ++
       integration_excluded ++
       vendor_conformance_excluded do
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
