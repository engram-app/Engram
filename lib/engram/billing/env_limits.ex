defmodule Engram.Billing.EnvLimits do
  @moduledoc """
  Boot-time parser for `ENGRAM_<TIER>_<KEY>` env vars that override
  per-tier plan limits. Raises with the env-var name on bad input so
  operators get a fail-fast boot crash rather than silent fallback.
  """

  @spec parse!(String.t(), :integer | :boolean | :string, String.t()) ::
          integer() | boolean() | String.t()
  def parse!(raw, :integer, env_name) do
    case Integer.parse(raw) do
      {n, ""} -> n
      _ -> raise ArgumentError, "#{env_name}: cannot parse #{inspect(raw)} as integer"
    end
  end

  def parse!("true", :boolean, _env_name), do: true
  def parse!("false", :boolean, _env_name), do: false

  def parse!(raw, :boolean, env_name),
    do: raise("#{env_name}: cannot parse #{inspect(raw)} as boolean (expected 'true' or 'false')")

  def parse!(raw, :string, _env_name) when is_binary(raw) and raw != "", do: raw

  def parse!(raw, :string, env_name),
    do: raise(ArgumentError, "#{env_name}: cannot parse #{inspect(raw)} as non-empty string")
end
