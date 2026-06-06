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
        assert html =~ "https://community.obsidian.md/plugins/engram-vault-sync",
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

  describe "send_account_deleted_notice/2" do
    test ":inactivity → auto-deleted subject + 90-day copy" do
      user = insert(:user, email: "u@example.com")

      expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
        assert to == "u@example.com"
        assert subject == "Engram: your vault was auto-deleted"
        assert html =~ "90 days of inactivity"
        :ok
      end)

      assert :ok = Mailer.send_account_deleted_notice(user, :inactivity)
    end

    test ":user → user-requested copy, not inactivity copy" do
      user = insert(:user, email: "u@example.com")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        assert subject == "Your Engram account has been deleted"
        assert html =~ "You requested account deletion"
        refute html =~ "inactivity"
        :ok
      end)

      assert :ok = Mailer.send_account_deleted_notice(user, :user)
    end

    test ":clerk → auth-provider copy" do
      user = insert(:user, email: "u@example.com")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        assert subject == "Your Engram account has been deleted"
        assert html =~ "authentication provider"
        refute html =~ "inactivity"
        :ok
      end)

      assert :ok = Mailer.send_account_deleted_notice(user, :clerk)
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
end
