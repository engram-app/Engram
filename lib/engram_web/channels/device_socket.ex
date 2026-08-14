defmodule EngramWeb.DeviceSocket do
  @moduledoc """
  Unauthenticated socket for the RFC 8628 device flow.

  The plugin holds no token until the flow completes — obtaining one IS the
  flow — so it cannot join `EngramWeb.UserSocket`, whose `connect/3` rejects
  any params without a `"token"`. That chicken-and-egg is why device-flow
  completion used to be a 5s polling loop.

  Authorization is scoped at the CHANNEL, not here: `connect/3` always
  succeeds (like `EngramWeb.OriginProbeSocket`) and `EngramWeb.DeviceChannel`
  refuses to join a topic whose `device_code` isn't real, pending and
  unexpired. A socket with no joined channel can do nothing.
  """
  use Phoenix.Socket

  channel("device:*", EngramWeb.DeviceChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
