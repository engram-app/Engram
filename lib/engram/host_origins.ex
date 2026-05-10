defmodule Engram.HostOrigins do
  @moduledoc """
  Parses the `PHX_HOST` env var into a canonical host plus a CORS/WebSocket
  allowlist. Accepts a single host or comma-separated list. Each entry is
  expanded to both `https://` and `http://` origins. Entries may include a
  port (e.g. `app.engram.page,engram.ax,10.0.20.214:8000`).

  The first non-empty entry is canonical (used for URL generation in
  `EngramWeb.Endpoint`).
  """

  @obsidian_origins ["app://obsidian.md", "capacitor://localhost", "http://localhost"]

  @type parsed :: %{canonical_host: String.t(), origins: [String.t()]}

  @spec parse(String.t() | nil) :: parsed | nil
  def parse(nil), do: nil
  def parse(""), do: nil

  def parse(raw) when is_binary(raw) do
    hosts =
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case hosts do
      [] ->
        nil

      [canonical | _] ->
        host_origins = Enum.flat_map(hosts, fn host -> ["https://#{host}", "http://#{host}"] end)
        %{canonical_host: canonical, origins: Enum.uniq(host_origins ++ @obsidian_origins)}
    end
  end
end
