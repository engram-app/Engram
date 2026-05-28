defmodule Engram.Telemetry do
  @moduledoc """
  Shared helpers for emitting telemetry safely.
  """

  @doc """
  Map an arbitrary failure reason to a bounded, log-safe atom for use as
  telemetry metadata.

  **Security invariant — never forward the raw reason.** A Redix/connection
  error term can carry the `REDIS_URL` (including its password), and a request
  error can carry a Voyage Bearer token; telemetry metadata does **not** pass
  through `Engram.Logger.RedactFilter`. Every caller that puts a failure reason
  into telemetry metadata must route it through here so only a bounded atom (an
  error class or exception module) escapes. The `is_atom/1` guard on the tuple
  clause is load-bearing: a `{non_atom, _}` falls through to `:other` rather
  than leaking the inner term.
  """
  @spec error_kind(term()) :: atom()
  def error_kind(reason) when is_atom(reason), do: reason
  def error_kind({kind, _}) when is_atom(kind), do: kind
  def error_kind(%{__exception__: true} = e), do: e.__struct__
  def error_kind(_), do: :other
end
