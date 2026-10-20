defmodule Engram.Workers.ConnectionCreatedTest do
  @moduledoc """
  The job behind a code exchange: tells the user's open vault tabs
  (`connection_created` on `user:{id}`) and, for an MCP client, sends one
  "you're connected" email. Only for the FIRST connection of a client: a
  re-authorization of a client the user already had in the last 30 days says
  nothing. Global app env, so not async.
  """
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Workers.ConnectionCreated

  setup :verify_on_exit!

  setup do
    prev_provider = Application.get_env(:engram, :email_provider)
    prev_base = Application.get_env(:engram, :frontend_base_url)
    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)
    Application.put_env(:engram, :frontend_base_url, "https://app.example.test/")

    on_exit(fn ->
      for {key, prev} <- [email_provider: prev_provider, frontend_base_url: prev_base] do
        if is_nil(prev),
          do: Application.delete_env(:engram, key),
          else: Application.put_env(:engram, key, prev)
      end
    end)

    user = insert(:user, email: "u@example.com", display_name: "Ada")
    client = insert(:oauth_client, client_name: "ChatGPT", kind: "mcp")
    EngramWeb.Endpoint.subscribe("user:#{user.id}")
    %{user: user, client: client}
  end

  defp job(user, client, connection_id \\ Ecto.UUID.generate(), attempt \\ 1) do
    %Oban.Job{
      attempt: attempt,
      args: %{
        "user_id" => user.id,
        "client_id" => client.client_id,
        "connection_id" => connection_id
      }
    }
  end

  defp family(user, client, attrs \\ []) do
    id = Ecto.UUID.generate()

    insert(
      :oauth_refresh_token,
      Keyword.merge([user_id: user.id, client_id: client.client_id, family_id: id], attrs)
    )

    id
  end

  test "a first MCP connection is announced and emailed", %{user: user, client: client} do
    connection = family(user, client)

    expect(Engram.Email.ProviderMock, :send, 1, fn "u@example.com", subject, html, _ ->
      assert subject == "ChatGPT is connected to Engram"
      assert html =~ ~s(href="https://app.example.test/")
      :ok
    end)

    assert :ok = ConnectionCreated.perform(job(user, client, connection))

    assert_receive %Phoenix.Socket.Broadcast{
      event: "connection_created",
      payload: %{client_name: "ChatGPT", kind: "mcp"}
    }
  end

  test "an Obsidian connection is announced but not emailed", %{user: user} do
    obsidian = insert(:oauth_client, client_name: "Obsidian", kind: "obsidian")
    assert :ok = ConnectionCreated.perform(job(user, obsidian, family(user, obsidian)))

    assert_receive %Phoenix.Socket.Broadcast{
      event: "connection_created",
      payload: %{kind: "obsidian"}
    }
  end

  test "a re-authorization of a client the user already has says nothing", %{
    user: user,
    client: client
  } do
    _earlier = family(user, client)
    assert :ok = ConnectionCreated.perform(job(user, client, family(user, client)))
    refute_receive %Phoenix.Socket.Broadcast{event: "connection_created"}, 50
  end

  test "one revoked within 30 days still counts as had", %{user: user, client: client} do
    _earlier = family(user, client, revoked_at: DateTime.add(DateTime.utc_now(:second), -3, :day))
    assert :ok = ConnectionCreated.perform(job(user, client, family(user, client)))
    refute_receive %Phoenix.Socket.Broadcast{event: "connection_created"}, 50
  end

  test "one gone for over 30 days does not", %{user: user, client: client} do
    long_ago = DateTime.add(DateTime.utc_now(:second), -40, :day)
    _old = family(user, client, revoked_at: long_ago, expires_at: long_ago)

    expect(Engram.Email.ProviderMock, :send, 1, fn _, _, _, _ -> :ok end)
    assert :ok = ConnectionCreated.perform(job(user, client, family(user, client)))
    assert_receive %Phoenix.Socket.Broadcast{event: "connection_created"}
  end

  test "a failed send is returned so Oban retries it", %{user: user, client: client} do
    connection = family(user, client)
    expect(Engram.Email.ProviderMock, :send, 1, fn _, _, _, _ -> {:error, :timeout} end)
    assert {:error, :timeout} = ConnectionCreated.perform(job(user, client, connection))
  end

  test "a retry sends the email without telling the tabs twice", %{user: user, client: client} do
    connection = family(user, client)
    expect(Engram.Email.ProviderMock, :send, 1, fn _, _, _, _ -> :ok end)
    assert :ok = ConnectionCreated.perform(job(user, client, connection, 2))
    refute_receive %Phoenix.Socket.Broadcast{event: "connection_created"}, 50
  end

  test "a suppressed address is not retried", %{user: user, client: client} do
    connection = family(user, client)
    expect(Engram.Email.ProviderMock, :send, 0, fn _, _, _, _ -> :ok end)
    insert_suppression!("u@example.com")
    assert :ok = ConnectionCreated.perform(job(user, client, connection))
  end

  test "the client name is escaped", %{user: user} do
    evil = insert(:oauth_client, client_name: "<script>x</script>", kind: "mcp")

    expect(Engram.Email.ProviderMock, :send, 1, fn _to, _subject, html, _opts ->
      refute html =~ "<script>"
      :ok
    end)

    assert :ok = ConnectionCreated.perform(job(user, evil, family(user, evil)))
  end

  test "a deleted user gets nothing", %{client: client} do
    gone = %Engram.Accounts.User{id: Ecto.UUID.generate()}
    assert :ok = ConnectionCreated.perform(job(gone, client))
  end

  test "is on the events queue with a finite timeout" do
    assert ConnectionCreated.__opts__()[:queue] == :events
    assert is_integer(ConnectionCreated.timeout(%Oban.Job{}))
  end

  defp insert_suppression!(email) do
    {:ok, _} = Engram.Email.Suppression.suppress(email, :bounced)
  end
end
