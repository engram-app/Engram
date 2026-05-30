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

    test "does not send to a suppressed address" do
      user = insert(:user)
      {:ok, _} = Engram.Email.Suppression.suppress(user.email, "bounced")

      # No expect/0 set → if the provider is called, Mox raises.
      assert {:error, :suppressed} = Mailer.send_welcome(user)
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
                 og_recipient("Ada"),
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
                 og_recipient("Ada"),
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

      assert :ok = Mailer.send_og_grandfather_3(og_recipient("Ada"))
    end

    test "escapes HTML in the recipient name" do
      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        refute html =~ "<script>"
        assert html =~ "&lt;script&gt;"
        :ok
      end)

      assert :ok =
               Mailer.send_og_grandfather_1(
                 og_recipient("<script>x</script>"),
                 "https://app.engram.page/checkout/og"
               )
    end
  end

  describe "send_welcome/1 — content assertions" do
    test "subject is 'Welcome to Engram'" do
      user = insert(:user, email: "user@example.com", display_name: "Sam")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, _html, _opts ->
        assert subject == "Welcome to Engram"
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end

    test "body greets the user by display_name" do
      user = insert(:user, email: "user@example.com", display_name: "Sam")

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        assert html =~ "Welcome to Engram, Sam"
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end

    test "body falls back to 'there' when display_name is nil" do
      user = insert(:user, email: "user@example.com", display_name: nil)

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        assert html =~ "Welcome to Engram, there"
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end

    test "body contains the install CTA link" do
      user = insert(:user, email: "user@example.com", display_name: "Sam")

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        assert html =~ "https://engram.page/install",
               "expected install CTA href"

        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end

    test "body references the memory framing, not just sync" do
      user = insert(:user, email: "user@example.com", display_name: "Sam")

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        assert html =~ "memory",
               "expected the memory-layer framing in the welcome body"

        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end
  end

  describe "send_vault_deletion_notice/4" do
    test "returns :ok and includes the manage link, vault name, and purge date" do
      user = insert(:user, email: "u@example.com")

      expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
        assert to == "u@example.com"
        assert subject =~ "vault was deleted"
        assert html =~ "My Vault"
        assert html =~ "June 27, 2026"
        assert html =~ "https://app.engram.page/settings/vaults?highlight=1"
        :ok
      end)

      assert :ok =
               Mailer.send_vault_deletion_notice(
                 user,
                 "My Vault",
                 "June 27, 2026",
                 "https://app.engram.page/settings/vaults?highlight=1"
               )
    end

    test "escapes HTML in the vault name" do
      user = insert(:user, email: "u@example.com")

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        refute html =~ "<script>alert(1)</script>"
        assert html =~ "&lt;script&gt;"
        :ok
      end)

      assert :ok =
               Mailer.send_vault_deletion_notice(
                 user,
                 "<script>alert(1)</script>",
                 "June 27, 2026",
                 "https://app.engram.page/settings/vaults?highlight=1"
               )
    end
  end

  defp og_recipient(name) do
    {:ok, r} = Engram.Email.Recipient.new("og@example.com", name)
    r
  end
end
