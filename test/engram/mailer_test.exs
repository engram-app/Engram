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

    test "without a display name the heading drops the name" do
      user = insert(:user, email: "user@example.com", display_name: nil)

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        assert html =~ "Welcome to Engram."
        refute html =~ "Welcome to Engram, "
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end

    test "is written in the user's stored language" do
      user = insert(:user, email: "user@example.com", locale: "de-AT")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, _html, _opts ->
        assert subject == Engram.I18n.t("de", "Welcome to Engram")
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

    test "copy contains no em dashes" do
      user = insert(:user, email: "user@example.com", display_name: "Sam")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        refute subject =~ "—", "house style: no em dashes in copy"
        refute html =~ "—", "house style: no em dashes in copy"
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
        refute html =~ "—", "house style: no em dashes in copy"
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

  describe "inactivity warnings" do
    test "60-day warning copy contains no em dashes" do
      user = insert(:user, email: "u@example.com")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        refute subject =~ "—", "house style: no em dashes in copy"
        refute html =~ "—", "house style: no em dashes in copy"
        :ok
      end)

      assert :ok = Mailer.send_inactivity_warning_60(user)
    end

    test "80-day warning copy contains no em dashes" do
      user = insert(:user, email: "u@example.com")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        refute subject =~ "—", "house style: no em dashes in copy"
        refute html =~ "—", "house style: no em dashes in copy"
        :ok
      end)

      assert :ok = Mailer.send_inactivity_warning_80(user)
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
        assert html =~ "https://app.engram.page/?highlight=1#settings/vaults"
        refute subject =~ "—", "house style: no em dashes in copy"
        refute html =~ "—", "house style: no em dashes in copy"
        :ok
      end)

      assert :ok =
               Mailer.send_vault_deletion_notice(
                 user,
                 "My Vault",
                 ~D[2026-06-27],
                 "https://app.engram.page/?highlight=1#settings/vaults"
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
                 ~D[2026-06-27],
                 "https://app.engram.page/?highlight=1#settings/vaults"
               )
    end
  end

  # The riskiest localized paths: a translated sentence with a user-supplied
  # var, the translated changelog nested in another sentence, and ISO dates.
  describe "send_connected/3" do
    setup do
      %{user: insert(:user, email: "c@example.com", display_name: "Ada")}
    end

    defp connected_html(user, client_name) do
      parent = self()

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        send(parent, {:sent, subject, html})
        :ok
      end)

      assert :ok = Mailer.send_connected(user, client_name, "https://app.example.test/")
      assert_received {:sent, subject, html}
      {subject, html}
    end

    test "leads with the heading, then what the client can do", %{user: user} do
      {subject, html} = connected_html(user, "ChatGPT")
      assert subject == "ChatGPT is connected to Engram"
      assert html =~ ~r/font-size:22px[^>]*>\s*(<[^>]+>\s*)*ChatGPT is connected</
      assert html =~ "Hi Ada,"
      assert html =~ "ChatGPT can now use the vaults you chose in your Engram account."
      assert html =~ "Ask ChatGPT to save a note, and it shows up in your vault."
      assert html =~ ~s(href="https://app.example.test/")
      refute html =~ "Open your vault any time"
      refute html =~ "is now connected to your Engram account"
      refute html =~ "—"
    end

    # The security line sits under the card, after the sign-off, as one
    # sentence with the link inside it.
    test "the disconnect line is below the card, with its link", %{user: user} do
      {_subject, html} = connected_html(user, "ChatGPT")
      [before_sign_off, after_sign_off] = String.split(html, "The Engram team", parts: 2)
      refute before_sign_off =~ "If you didn&#39;t connect"
      assert after_sign_off =~ "If you didn&#39;t connect ChatGPT,"

      assert after_sign_off =~
               ~r{<a href="https://app.example.test/#settings/connections" style="color:#7c3aed;">disconnect it in your connections</a>\.}

      [footer, _tagline] = String.split(after_sign_off, "Your notes are your AI", parts: 2)
      assert footer =~ "disconnect it in your connections"
    end

    test "a client with no name reads as your AI tool", %{user: user} do
      {subject, html} = connected_html(user, nil)
      assert subject == "Your AI tool is connected to Engram"
      assert html =~ "Your AI tool is connected"
      assert html =~ "Your AI tool can now use the vaults you chose in your Engram account."
      assert html =~ "Ask your AI tool to save a note, and it shows up in your vault."
      assert html =~ "If you didn&#39;t connect this tool,"
    end

    # The link survives translation: `{link}` is a placeholder in the key.
    test "a translated email keeps the link inside its sentence" do
      user = insert(:user, email: "d@example.com", locale: "de")
      {_subject, html} = connected_html(user, "ChatGPT")
      assert html =~ "ChatGPT ist verbunden"
      assert html =~ ~s(<a href="https://app.example.test/#settings/connections")
      refute html =~ "{link}"
      refute html =~ "\uE000"
    end

    test "the client name is escaped everywhere, the link is not", %{user: user} do
      {_subject, html} = connected_html(user, "<b>x</b>")
      refute html =~ "<b>x</b>"
      assert html =~ "&lt;b&gt;x&lt;/b&gt;"
      assert html =~ ~s(<a href="https://app.example.test/#settings/connections")
    end
  end

  describe "localized (de)" do
    test "legal notice: translated subject, changelog and ISO date" do
      user = insert(:user, email: "u@example.com", locale: "de")

      version = %Engram.Legal.TermsVersion{
        document: "privacy_policy",
        version: "2026-10-12",
        material: false,
        effective_date: ~D[2026-11-11],
        changelog:
          "App analytics now linked to your account (email, plan, usage counts). The content of your notes is never sent."
      }

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        assert subject == Engram.I18n.t("de", "Engram Privacy Policy Update")
        assert html =~ "2026-11-11"
        refute html =~ "November"

        changelog = Engram.I18n.t("de", version.changelog)
        refute changelog == version.changelog, "the changelog must be translated"

        expected =
          Engram.I18n.t("de", "Summary of the changes: {changelog}", changelog: changelog)
          |> Engram.Email.Template.esc()

        assert html =~ expected
        :ok
      end)

      assert :ok = Mailer.send_legal_notice(user, version, "notice")
    end

    test "vault deletion: escapes the vault name inside the translated sentence" do
      user = insert(:user, email: "u@example.com", locale: "de")

      expect(Engram.Email.ProviderMock, :send, fn _to, subject, html, _opts ->
        assert subject == Engram.I18n.t("de", "Your Engram vault was deleted")
        refute html =~ "<script>alert(1)</script>"

        expected =
          Engram.I18n.t("de", "Your Engram vault \"{vault}\" has been deleted.",
            vault: "<script>alert(1)</script>"
          )
          |> Engram.Email.Template.esc()

        assert html =~ expected
        assert html =~ "2026-06-27"
        :ok
      end)

      assert :ok =
               Mailer.send_vault_deletion_notice(
                 user,
                 "<script>alert(1)</script>",
                 ~D[2026-06-27],
                 "https://app.engram.page/?highlight=1#settings/vaults"
               )
    end
  end
end
