defmodule Engram.Test.StubResolver do
  @moduledoc """
  The address check `Engram.OAuth.Cimd` runs on a document's `jwks_uri`, with
  DNS stubbed so tests never touch the network: `private.example` resolves to
  10.0.0.7 and every other name to a public address. IP literals go through
  `Engram.Http.SsrfGuard` unchanged.
  """

  alias Engram.Http.SsrfGuard

  @spec resolve(String.t()) :: {:ok, SsrfGuard.target()} | {:error, SsrfGuard.reason()}
  def resolve(url), do: SsrfGuard.resolve(url, getaddrs: &getaddrs/2)

  defp getaddrs(~c"private.example", :inet), do: {:ok, [{10, 0, 0, 7}]}
  defp getaddrs(_host, :inet), do: {:ok, [{93, 184, 216, 34}]}
  defp getaddrs(_host, :inet6), do: {:error, :nxdomain}
end
