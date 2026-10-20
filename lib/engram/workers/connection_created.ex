defmodule Engram.Workers.ConnectedEmail do
  @moduledoc """
  Oban worker: the "you're connected" email for a new MCP connection
  (`Engram.OAuth` enqueues it on a successful code exchange). Unique per
  connection for good, so a retried exchange or enqueue never sends twice.
  Self-host no-ops via the NoOp mail provider.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [keys: [:connection_id], period: :infinity]

  alias Engram.Accounts.User
  alias Engram.Mailer
  alias Engram.Repo

  require Logger

  @doc "Queues the email for connection `connection_id` (the token family id)."
  def enqueue(user_id, connection_id, client_name) do
    %{user_id: user_id, connection_id: connection_id, client_name: client_name}
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      # The connection already works; a lost email must not fail the exchange.
      {:error, reason} ->
        Logger.warning(
          "connected_email_enqueue_failed",
          Engram.Logger.Metadata.with_category(:warning, :lifecycle,
            reason: Engram.Logger.Metadata.safe_reason(reason)
          )
        )

        :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
    case Repo.get(User, user_id) do
      nil ->
        :ok

      user ->
        _ = Mailer.send_connected(user, args["client_name"], app_url())
        :ok
    end
  end

  # The SPA host (app.engram.page in SaaS), not this endpoint's api/mcp host;
  # self-host serves both from one origin. Same choice as
  # `EngramWeb.Plugs.RequireOnboarding`.
  defp app_url do
    case Application.get_env(:engram, :frontend_base_url) do
      url when is_binary(url) and url != "" -> url
      _ -> EngramWeb.Endpoint.url()
    end
  end
end
