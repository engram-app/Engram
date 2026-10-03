defmodule Engram.Telemetry.Heartbeat do
  @moduledoc """
  Self-host install census. One daily POST of {id, version, os, arch, runtime}
  so we can count installs and platforms. Nothing else is ever sent: no counts,
  no hostnames, no user data. Opt-in (`Instance.telemetry_enabled/0`); off on
  SaaS and whenever `DO_NOT_TRACK=1` or `ENGRAM_TELEMETRY=off`.
  """
  alias Engram.Instance

  @url "https://api.engram.page/api/telemetry/ping"

  def enabled? do
    not Application.get_env(:engram, :billing_enabled, false) and
      System.get_env("DO_NOT_TRACK") != "1" and
      System.get_env("ENGRAM_TELEMETRY") != "off" and
      Instance.telemetry_enabled() == true
  end

  def payload do
    %{
      id: Instance.install_id(),
      version: to_string(Application.spec(:engram, :vsn)),
      os: os(),
      arch: arch(),
      runtime: runtime()
    }
  end

  def send_ping do
    opts = Application.get_env(:engram, :telemetry_req_options, [])
    Req.post(@url, [json: payload(), receive_timeout: 5_000, retry: false] ++ opts)
  end

  defp os do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      {:win32, _} -> "windows"
      _ -> "other"
    end
  end

  defp arch do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.starts_with?(arch, ["x86_64", "amd64"]) -> "amd64"
      String.starts_with?(arch, ["aarch64", "arm64"]) -> "arm64"
      true -> "other"
    end
  end

  defp runtime do
    if File.exists?("/.dockerenv") or File.exists?("/run/.containerenv"),
      do: "docker",
      else: "source"
  end
end
