defmodule Engram.Crypto.DekUnavailableError do
  @moduledoc """
  Raised by a request that cannot go on without the user's DEK. Rendered as a
  503 `dek_unavailable` when the failure is transient
  (`Engram.Crypto.transient_dek_error?/1`), so the client retries, and as a
  500 for a real crypto fault. The 503's Retry-After comes from
  `EngramWeb.Plugs.RetryAfter`.
  """
  defexception [:reason, plug_status: 500]

  @impl true
  def exception(reason) do
    status = if Engram.Crypto.transient_dek_error?(reason), do: 503, else: 500
    %__MODULE__{reason: reason, plug_status: status}
  end

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "DEK unavailable (#{Engram.Crypto.format_dek_error(reason)})"
end
