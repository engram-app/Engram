defmodule Engram.SpaIntegrity do
  @moduledoc """
  Boot-time check that every `/assets/*` URL referenced in
  `priv/static/app/index.html` actually exists on disk.

  Catches stale Docker layer caches or botched release tarballs that ship
  an index.html referencing assets that aren't there. Without this guard,
  Plug.Static returns 404 for the missing JS, the browser MIME-fails on
  the `<script>` tag, the React app never mounts, and the user sees a
  blank page with zero log signal.

  Related: `docs/context/docker-build-cache-pitfalls.md`.

  Gated by `:engram, :spa_integrity_check_enabled` (defaults to false so
  test/dev — where vite serves the SPA separately — don't have to maintain
  a fake build). `runtime.exs` flips it on in `:prod`.

  Note: this is a static check against `index.html`. Dynamic `import()`
  calls embedded in JS bundles (Vite code-splits not referenced from a
  `<link rel="modulepreload">` tag) are NOT validated here; missing
  chunks of that shape surface only at runtime as a failed fetch.
  """

  require Logger

  @asset_ref_regex ~r{(?:src|href)=["'](/assets/[^"']+)["']}

  @doc """
  Verify SPA build integrity. Raises on missing index.html or any
  referenced asset that isn't on disk. Returns `:ok` otherwise.

  ## Options

    * `:static_root` — directory housing `index.html` and `assets/`.
      Defaults to `Application.app_dir(:engram, "priv/static/app")`.
  """
  @spec verify!(keyword()) :: :ok
  def verify!(opts \\ []) do
    static_root = opts[:static_root] || Application.app_dir(:engram, "priv/static/app")
    index_path = Path.join(static_root, "index.html")

    html =
      case File.read(index_path) do
        {:ok, content} ->
          content

        {:error, reason} ->
          fail!("cannot read #{index_path} (#{inspect(reason)})")
      end

    missing =
      @asset_ref_regex
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(fn url_path ->
        File.exists?(Path.join(static_root, String.trim_leading(url_path, "/")))
      end)

    case missing do
      [] -> :ok
      refs -> fail!("index.html references missing assets: " <> Enum.join(refs, ", "))
    end
  end

  # Log before raising so the structured log pipeline captures the failure
  # before the VM dies — otherwise an OTP :start_error tuple to stderr is the
  # only signal, and Fly/K8s restart-loops without an obvious cause.
  @spec fail!(String.t()) :: no_return()
  defp fail!(reason) do
    Logger.error(
      "SPA integrity check failed: #{reason}",
      Engram.Logger.Metadata.with_category(:error, :boot, [])
    )

    raise "SPA integrity check failed: #{reason}"
  end
end
