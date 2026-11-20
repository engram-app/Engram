defmodule Engram.Workers.QuarantineDisconnect do
  @moduledoc """
  Second force-disconnect of a quarantined user's sockets, 61 s after the
  quarantine was set. The first disconnect can race a node whose user cache has
  not yet seen the new row, letting the client rejoin; by +61 s every cache has
  expired or been evicted.

  Re-checks the quarantine first: if it was lifted or expired in between, the
  user is already admitted and a second drop would only bounce a healthy socket.
  """
  # `:events`: a small follow-up a user's action (an operator's quarantine)
  # triggers, never behind a long backstop.
  use Oban.Worker, queue: :events, max_attempts: 3

  alias Engram.Auth.SessionInvalidator
  alias Engram.ClientGate

  # One PubSub broadcast and one cached read: seconds at most.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case ClientGate.paused(%{id: user_id}) do
      {:error, %{reason: "account_paused"}} -> SessionInvalidator.disconnect_user(user_id)
      :ok -> :ok
    end
  end
end
