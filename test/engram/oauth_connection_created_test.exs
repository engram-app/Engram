defmodule Engram.OAuthConnectionCreatedTest do
  @moduledoc """
  A code exchange queues `Engram.Workers.ConnectionCreated` (notice + email)
  and does nothing else on its own path: the exchange has already consumed
  the code and minted the tokens, so a failing side effect must never turn
  into a 500. A client retrying a 500 replays the consumed code, and a replay
  REVOKES the family it just minted. Global app env, so not async.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]
  import ExUnit.CaptureLog

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.Workers.ConnectionCreated

  @redirect "https://claude.ai/api/mcp/auth_callback"

  defmodule RaisingAnnouncer do
    def enqueue(_user_id, _client_id, _connection_id), do: raise("announce exploded")
  end

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

  test "an exchange queues one announce job and broadcasts nothing itself", %{
    user: user,
    client: client
  } do
    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, client))

    assert [%Oban.Job{args: args}] = all_enqueued(worker: ConnectionCreated)
    assert args["user_id"] == user.id
    assert is_binary(args["client_id"])
    assert is_binary(args["connection_id"])
    refute_receive %Phoenix.Socket.Broadcast{event: "connection_created"}, 50
  end

  test "one job per user and client: a re-authorization queues nothing new", %{
    user: user,
    client: client
  } do
    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, client))
    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, client))
    assert [_one] = all_enqueued(worker: ConnectionCreated)

    {:ok, other} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Cursor"})

    assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(user, other))
    assert [_, _] = all_enqueued(worker: ConnectionCreated)
  end

  test "a refused exchange queues nothing", %{user: user, client: client} do
    params = %{exchange_params(user, client) | "code_verifier" => "wrong"}
    assert {:error, {:invalid_grant, _}} = OAuth.exchange_authorization_code(params)
    assert [] = all_enqueued(worker: ConnectionCreated)
  end

  test "a raising announce still returns the token and revokes nothing", %{
    user: user,
    client: client
  } do
    prev = Application.get_env(:engram, :connection_announcer)
    Application.put_env(:engram, :connection_announcer, RaisingAnnouncer)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :connection_announcer, prev),
        else: Application.delete_env(:engram, :connection_announcer)
    end)

    log =
      capture_log(fn ->
        assert {:ok, %{refresh_token: _}} =
                 OAuth.exchange_authorization_code(exchange_params(user, client))
      end)

    assert log =~ "oauth_connection_announce_failed"

    assert [%RefreshToken{revoked_at: nil}] =
             Repo.all(from(t in RefreshToken, where: t.user_id == ^user.id))
  end
end
