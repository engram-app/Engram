defmodule Engram.MailerTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Mailer

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

  describe "send_welcome/1" do
    test "sends a welcome email to the user's address" do
      user = insert(:user)

      expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
        assert to == user.email
        assert subject =~ "Welcome"
        assert html =~ "Engram"
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end

    test "escapes HTML in the user's display name" do
      user = insert(:user, display_name: "<script>alert(1)</script>")

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        refute html =~ "<script>alert(1)</script>"
        assert html =~ "&lt;script&gt;"
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end
  end

  describe "OG-waitlist grandfather emails" do
    test "email 1 — pricing-locked heads-up with checkout link" do
      expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
        assert to == "og@example.com"
        assert subject =~ "founding-member pricing is locked"
        assert html =~ "Ada"
        assert html =~ "https://app.engram.page/checkout/og"
        assert html =~ "$5"
        assert html =~ "12 months"
        :ok
      end)

      assert :ok =
               Mailer.send_og_grandfather_1(
                 "og@example.com",
                 "Ada",
                 "https://app.engram.page/checkout/og"
               )
    end

    test "email 2 — expiry reminder with date and portal link" do
      expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
        assert to == "og@example.com"
        assert subject =~ "expires in 30 days"
        assert html =~ "Ada"
        assert html =~ "June 1, 2027"
        assert html =~ "https://app.engram.page/portal"
        :ok
      end)

      assert :ok =
               Mailer.send_og_grandfather_2(
                 "og@example.com",
                 "Ada",
                 "June 1, 2027",
                 "https://app.engram.page/portal"
               )
    end

    test "email 3 — post-expiry notice" do
      expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
        assert to == "og@example.com"
        assert subject =~ "pricing has updated"
        assert html =~ "Ada"
        assert html =~ "standard rate"
        :ok
      end)

      assert :ok = Mailer.send_og_grandfather_3("og@example.com", "Ada")
    end

    test "escapes HTML in the recipient name" do
      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        refute html =~ "<script>"
        assert html =~ "&lt;script&gt;"
        :ok
      end)

      assert :ok =
               Mailer.send_og_grandfather_1(
                 "og@example.com",
                 "<script>x</script>",
                 "https://app.engram.page/checkout/og"
               )
    end
  end
end
