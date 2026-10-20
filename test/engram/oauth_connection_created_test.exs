defmodule Engram.OAuthConnectionCreatedTest do
  @moduledoc """
  A code exchange is the moment a connection exists. It tells the user's open
  web tabs (`connection_created` on `user:{id}`) and, for an MCP client, queues
  one "you're connected" email per connection. The consent tab hands straight
  back to the client, so this is how the user reaches their vault.
  """
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth
  alias Engram.Workers.ConnectedEmail

  @redirect "https://claude.ai/api/mcp/auth_callback"

  defp exchange_params(user, client) do
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    %{
      "grant_type" => "authorization_code",
      "code" => code_from_redirect(url),
      "redirect_uri" => @redirect,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    }
  end

  setup do
    user = insert(:user)
    EngramWeb.Endpoint.subscribe("user:#{user.id}")

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Claude"})

    %{user: user, client: client}
  end

  test "an MCP code exchange broadcasts connection_created and queues one email", %{
    user: user,
    client: client
  } do
    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, client))

    assert_receive %Phoenix.Socket.Broadcast{
      topic: topic,
      event: "connection_created",
      payload: %{client_name: "Claude", kind: "mcp"}
    }

    assert topic == "user:#{user.id}"
    assert [%Oban.Job{args: args}] = all_enqueued(worker: ConnectedEmail)
    assert args["user_id"] == user.id
    assert args["client_name"] == "Claude"
    assert is_binary(args["connection_id"])
  end

  test "one email per connection: a retried enqueue never doubles it", %{
    user: user,
    client: client
  } do
    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, client))
    assert [%Oban.Job{args: args}] = all_enqueued(worker: ConnectedEmail)

    ConnectedEmail.enqueue(user.id, args["connection_id"], "Claude")
    assert [_one] = all_enqueued(worker: ConnectedEmail)

    # A second connection is a second email.
    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, client))
    assert [_, _] = all_enqueued(worker: ConnectedEmail)
  end

  test "an Obsidian client is announced to the tabs but gets no email", %{user: user} do
    client =
      insert(:oauth_client, kind: "obsidian", client_name: "Obsidian", redirect_uris: [@redirect])

    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, client))

    assert_receive %Phoenix.Socket.Broadcast{
      event: "connection_created",
      payload: %{kind: "obsidian"}
    }

    assert [] = all_enqueued(worker: ConnectedEmail)
  end

  test "a refused exchange announces nothing", %{user: user, client: client} do
    params = %{exchange_params(user, client) | "code_verifier" => "wrong"}
    assert {:error, {:invalid_grant, _}} = OAuth.exchange_authorization_code(params)

    refute_receive %Phoenix.Socket.Broadcast{event: "connection_created"}, 50
    assert [] = all_enqueued(worker: ConnectedEmail)
  end
end
