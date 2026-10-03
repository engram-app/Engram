defmodule Engram.Telemetry.Heartbeat do
  @moduledoc """
  Self-host install census. One daily POST of {id, version, os, arch, runtime}
  so we can count installs and platforms. Nothing else is ever sent: no counts,
  no hostnames, no user data.

  On by default for self-host: an operator who has not answered
  (`Instance.telemetry_enabled/0` is `nil`) counts as on. Off on SaaS, when the
  operator turned it off in the admin UI, and whenever `DO_NOT_TRACK=1` or
  `ENGRAM_TELEMETRY=off`.
  """
  alias Engram.Instance

  require Logger

  @url "https://api.engram.page/api/telemetry/ping"

  def enabled? do
    not Application.get_env(:engram, :billing_enabled, false) and
      not env_disabled?() and
      Instance.telemetry_enabled() != false
  end

  @doc """
  One boot-time line so the default is never silent. Needs no DB read, so it
  names the switches instead of reporting the stored answer.
  """
  def log_boot_notice do
    if Application.get_env(:engram, :billing_enabled, false) or env_disabled?() do
      :ok
    else
      Logger.info(
        "Engram sends an anonymous daily usage ping (install id, version, OS, arch, runtime). " <>
          "Turn it off with ENGRAM_TELEMETRY=off, DO_NOT_TRACK=1, or Administration > Usage statistics."
      )
    end
  end

  @doc "True when the operator's environment forbids telemetry, whatever the stored answer says."
  def env_disabled? do
    System.get_env("DO_NOT_TRACK") == "1" or System.get_env("ENGRAM_TELEMETRY") == "off"
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
