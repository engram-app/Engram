defmodule Engram.Workers.ConnectedEmailTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Workers.ConnectedEmail

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

    %{user: insert(:user, email: "u@example.com", display_name: "Ada")}
  end

  defp job(user_id),
    do: %Oban.Job{
      args: %{
        "user_id" => user_id,
        "connection_id" => Ecto.UUID.generate(),
        "client_name" => "ChatGPT"
      }
    }

  test "sends one email naming the client, with the vault link, in our voice", %{user: user} do
    expect(Engram.Email.ProviderMock, :send, 1, fn to, subject, html, _opts ->
      assert to == "u@example.com"
      assert subject == "ChatGPT is connected to Engram"
      assert html =~ "Hi Ada,"
      assert html =~ ~s(href="https://app.example.test/")
      assert html =~ ~s(href="https://app.example.test/#settings/connections")
      assert html =~ "The Engram team"
      refute html =~ "—"
      :ok
    end)

    assert :ok = ConnectedEmail.perform(job(user.id))
  end

  test "the client name is escaped", %{user: user} do
    expect(Engram.Email.ProviderMock, :send, 1, fn _to, _subject, html, _opts ->
      refute html =~ "<script>"
      :ok
    end)

    job = %Oban.Job{
      args: %{
        "user_id" => user.id,
        "connection_id" => Ecto.UUID.generate(),
        "client_name" => "<script>x</script>"
      }
    }

    assert :ok = ConnectedEmail.perform(job)
  end

  test "a deleted user gets nothing" do
    assert :ok = ConnectedEmail.perform(job(Ecto.UUID.generate()))
  end
end
