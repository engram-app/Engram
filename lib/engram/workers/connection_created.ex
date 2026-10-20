defmodule Engram.Workers.ConnectionCreated do
  @moduledoc """
  Oban worker: what a successful OAuth code exchange announces, run off the
  exchange path (`Engram.OAuth` enqueues it) so a failure here can never fail
  a token response.

  For a user's FIRST connection of a client (none of theirs active in the
  last 30 days, see `Engram.OAuth.prior_connection?/3`) it:

    * broadcasts `connection_created` on `user:{id}`, which an open vault tab
      shows as "{client} is connected" (first attempt only, so a retried
      email does not repeat it);
    * for an MCP client, sends the "you're connected" email with the vault
      link (`Engram.Mailer.send_connected/3`). A failed send is returned, so
      Oban retries it; a suppressed address is not retried.

  Unique per (user, client) for 30 days, so re-authorizing queues nothing new.
  Self-host sends nothing via the NoOp mail provider.
  """

  use Oban.Worker,
    queue: :events,
    max_attempts: 3,
    # 30 days, the same look-back as `OAuth.prior_connection?/3`.
    unique: [keys: [:user_id, :client_id], period: 30 * 24 * 3600]

  alias Engram.Accounts.User
  alias Engram.Mailer
  alias Engram.OAuth
  alias Engram.OAuth.Client
  alias Engram.Repo

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @doc "Queues the announce for connection `connection_id` (the token family id)."
  def enqueue(user_id, client_id, connection_id) do
    %{user_id: user_id, client_id: client_id, connection_id: connection_id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, args: args}) do
    %{"user_id" => user_id, "client_id" => client_id, "connection_id" => connection_id} = args

    with %User{} = user <- Repo.get(User, user_id),
         %Client{} = client <- Repo.get(Client, client_id),
         false <- OAuth.prior_connection?(user_id, client_id, connection_id) do
      if attempt == 1, do: broadcast(user_id, client)
      if client.kind == "mcp", do: email(user, client), else: :ok
    else
      _ -> :ok
    end
  end

  defp broadcast(user_id, client) do
    _ =
      EngramWeb.Endpoint.broadcast("user:#{user_id}", "connection_created", %{
        client_name: client.client_name,
        kind: client.kind
      })

    :ok
  end

  defp email(user, client) do
    case Mailer.send_connected(user, client.client_name, app_url()) do
      {:error, :suppressed} -> :ok
      {:error, _reason} = error -> error
      _ok -> :ok
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
