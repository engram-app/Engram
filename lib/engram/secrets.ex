defmodule Engram.Secrets do
  @moduledoc """
  Prod delivers all app secrets as a single SSM SecureString JSON blob
  (`APP_SECRETS_JSON`) so the task incurs one `kms:Decrypt` instead of one
  per secret. `unpack/2` expands that blob into a map suitable for
  `System.put_env/1`. Self-host/dev set individual env vars and never set
  the blob, so this is a no-op there.

  An individually-set env var always wins over the blob — this preserves
  per-key emergency overrides and makes the migration window safe.
  """

  @doc """
  Given the blob string (or nil) and an env-lookup function, returns the
  `%{name => value}` pairs to inject. Keys already present (lookup returns a
  non-nil value) are excluded. Raises on malformed or non-object JSON.
  """
  @spec unpack(String.t() | nil, (String.t() -> String.t() | nil)) ::
          %{String.t() => String.t()}
  def unpack(nil, _getenv), do: %{}

  def unpack(blob, getenv) when is_binary(blob) and is_function(getenv, 1) do
    case Jason.decode!(blob) do
      map when is_map(map) ->
        map
        |> Enum.reject(fn {k, _v} -> getenv.(k) != nil end)
        |> Map.new(fn {k, v} -> {k, to_string(v)} end)

      other ->
        raise ArgumentError,
              "APP_SECRETS_JSON must be a JSON object, got: #{inspect(other)}"
    end
  end
end
