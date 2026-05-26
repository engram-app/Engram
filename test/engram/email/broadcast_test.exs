defmodule Engram.Email.BroadcastTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Email.Broadcast

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

  describe "run/3 with send" do
    test "sends the og3 template to every recipient and tallies sent" do
      rows = [%{email: "a@example.com", name: "A"}, %{email: "b@example.com", name: "B"}]

      expect(Engram.Email.ProviderMock, :send, 2, fn _to, _subject, _html, _opts -> :ok end)

      assert %{sent: 2, failed: []} = Broadcast.run(:og3, rows, send?: true)
    end

    test "collects per-recipient failures instead of crashing" do
      rows = [%{email: "ok@example.com", name: "A"}, %{email: "bad@example.com", name: "B"}]

      expect(Engram.Email.ProviderMock, :send, 2, fn to, _subject, _html, _opts ->
        if to == "bad@example.com", do: {:error, :boom}, else: :ok
      end)

      assert %{sent: 1, failed: [{"bad@example.com", :boom}]} =
               Broadcast.run(:og3, rows, send?: true)
    end

    test "og1 passes the checkout_url through to the template" do
      rows = [%{email: "a@example.com", name: "A"}]

      expect(Engram.Email.ProviderMock, :send, 1, fn _to, _subject, html, _opts ->
        assert html =~ "https://app.engram.page/checkout/og"
        :ok
      end)

      assert %{sent: 1, failed: []} =
               Broadcast.run(:og1, rows,
                 send?: true,
                 checkout_url: "https://app.engram.page/checkout/og"
               )
    end
  end

  describe "run/3 dry-run (default)" do
    test "does not send and reports the recipient count" do
      rows = [%{email: "a@example.com", name: "A"}, %{email: "b@example.com", name: "B"}]

      # No expect/0 set → if Broadcast calls the provider, Mox raises.
      assert %{dry_run: true, recipients: 2, sent: 0, failed: []} = Broadcast.run(:og3, rows, [])
    end
  end
end
