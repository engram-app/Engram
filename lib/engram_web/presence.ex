defmodule EngramWeb.Presence do
  @moduledoc "Phoenix Presence tracker for connected sync devices, keyed per-user/per-vault."
  use Phoenix.Presence,
    otp_app: :engram,
    pubsub_server: Engram.PubSub
end
