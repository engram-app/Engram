defmodule EngramWeb.DeviceChannel do
  @moduledoc """
  Pre-auth notification channel for the device flow. Topic:
  `"device:{device_code}"`.

  Replaces the plugin's polling loop: when the user authorizes in the
  browser, subscribers are pushed an `"authorized"` event and exchange the
  code for tokens once, instead of asking every 5 seconds whether anything
  happened yet.

  ## Why a notification and not the tokens

  A broadcast reaches every subscriber to a topic at once; the token exchange
  is single-use, so the first caller consumes the code and the rest get 410.
  Putting credentials on the channel would therefore be strictly WEAKER than
  the REST endpoint it replaces. The channel says "go exchange now"; the
  exchange stays exactly where it was.

  ## Why the topic can be named by the device_code

  Under RFC 8628 the `device_code` is already the bearer credential for the
  token exchange, so knowing it is equivalent to being able to redeem it —
  subscribing leaks nothing that POSTing it wouldn't. It carries 256 bits of
  entropy, is single-use, and expires in 300s. Phoenix routes topics by exact
  name, so there is nothing to enumerate.

  Join is still gated on the code being real, pending and unexpired: without
  that, the topic space would be an unauthenticated, unbounded fan-out
  surface that anyone could hold subscriptions against indefinitely.
  """
  use EngramWeb, :channel

  alias Engram.Auth.DeviceFlow

  @impl true
  def join("device:" <> device_code, _payload, socket) when byte_size(device_code) > 0 do
    if DeviceFlow.pending_device_code?(device_code) do
      {:ok, socket}
    else
      {:error, %{reason: "unknown_or_expired"}}
    end
  end

  @impl true
  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}
end
