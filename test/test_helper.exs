ExUnit.start(assert_receive_timeout: 2_000)
Ecto.Adapters.SQL.Sandbox.mode(Engram.Repo, :manual)

# Capture log output during tests. Logger messages are buffered per-test and
# only re-emitted to stdout when that test FAILS — green tests stay silent.
# This hides intentional-error-path noise (e.g. `vault decrypt_failed`
# reason=:no_dek from test factories that skip DEK provisioning) while
# preserving full diagnostic output for real failures.
ExUnit.configure(capture_log: true)

# Exclude :qdrant_integration tests unless QDRANT_INTEGRATION=1 is set.
# These tests require a running Qdrant instance at localhost:6333 (CI stack).
if System.get_env("QDRANT_INTEGRATION") != "1" do
  ExUnit.configure(exclude: [:qdrant_integration])
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
