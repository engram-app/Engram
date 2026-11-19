defmodule Engram.Workers.QuarantineDisconnect do
  @moduledoc """
  Second force-disconnect of a quarantined user's sockets, 61 s after the
  quarantine was set. The first disconnect can race a node whose user cache has
  not yet seen the new row, letting the client rejoin; by +61 s every cache has
  expired or been evicted. Harmless if the quarantine was lifted meanwhile.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}),
    do: Engram.Auth.SessionInvalidator.disconnect_user(user_id)
end
