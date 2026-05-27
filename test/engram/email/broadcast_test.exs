defmodule Engram.Email.BroadcastTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Email.Broadcast
  alias Engram.Email.Broadcast.{OG1, OG3}
  alias Engram.Email.Recipient

  setup :verify_on_exit!

  setup do
    prev_provider = Application.get_env(:engram, :email_provider)
    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)

    on_exit(fn ->
      if is_nil(prev_provider),
        do: Application.delete_env(:engram, :email_provider),
        else: Application.put_env(:engram, :email_provider, prev_provider)
    end)

    :ok
  end

  defp recipient(email, name \\ "X") do
    {:ok, r} = Recipient.new(email, name)
    r
  end

  describe "run/3 with send" do
    test "sends the og3 template to every recipient and tallies sent" do
      recipients = [recipient("a@example.com"), recipient("b@example.com")]

      expect(Engram.Email.ProviderMock, :send, 2, fn _to, _subject, _html, _opts -> :ok end)

      assert {:sent, %{sent: 2, failed: []}} = Broadcast.run(%OG3{}, recipients, send?: true)
    end

    test "collects per-recipient failures instead of crashing" do
      recipients = [recipient("ok@example.com"), recipient("bad@example.com")]

      expect(Engram.Email.ProviderMock, :send, 2, fn to, _subject, _html, _opts ->
        if to == "bad@example.com", do: {:error, :boom}, else: :ok
      end)

      assert {:sent, %{sent: 1, failed: [{"bad@example.com", :boom}]}} =
               Broadcast.run(%OG3{}, recipients, send?: true)
    end

    test "og1 passes the checkout_url through to the template" do
      expect(Engram.Email.ProviderMock, :send, 1, fn _to, _subject, html, _opts ->
        assert html =~ "https://app.engram.page/checkout/og"
        :ok
      end)

      assert {:sent, %{sent: 1, failed: []}} =
               Broadcast.run(
                 %OG1{checkout_url: "https://app.engram.page/checkout/og"},
                 [recipient("a@example.com")],
                 send?: true
               )
    end
  end

  describe "run/3 dry-run (default)" do
    test "does not send and reports the recipient count" do
      recipients = [recipient("a@example.com"), recipient("b@example.com")]

      # No expect/0 set → if Broadcast calls the provider, Mox raises.
      assert {:dry_run, %{recipients: 2}} = Broadcast.run(%OG3{}, recipients, [])
    end
  end
end
