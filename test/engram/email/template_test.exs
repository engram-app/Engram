defmodule Engram.Email.TemplateTest do
  use ExUnit.Case, async: true

  alias Engram.Email.Template
  alias Engram.Email.Tokens

  describe "render/1" do
    setup do
      {:ok, html} = Template.render("<mj-text>Hello there</mj-text>")
      %{html: html}
    end

    test "wraps the body in the brand layout", %{html: html} do
      assert html =~ "Hello there"
      assert html =~ "Engram"
    end

    test "uses the marketing-token brand purple, not hardcoded #5b5bd6", %{html: html} do
      assert html =~ Tokens.brand_purple()
      refute html =~ "#5b5bd6"
    end

    test "includes the mark image from the configured endpoint", %{html: html} do
      assert html =~ "/email/engram-mark.png",
             "expected the mark URL to appear in the rendered HTML"
    end

    test "footer copy matches the memory-layer positioning", %{html: html} do
      # MJML passes apostrophes through unescaped (literal U+0027, not &#x27;).
      # The assertion uses the literal character — verified against rendered output.
      assert html =~ "Your notes are your AI\x27s memory.",
             ~S[expected the footer phrase "Your notes are your AI's memory." in rendered HTML]
    end

    test "drops the old footer phrase entirely", %{html: html} do
      refute html =~ "synced everywhere",
             "the legacy footer copy must be removed"
    end
  end

  describe "render/1 error handling" do
    test "returns {:error, reason} on invalid MJML instead of raising" do
      assert {:error, _reason} = Template.render("<<< not mjml")
    end
  end

  describe "esc/1" do
    test "HTML-escapes markup" do
      assert Template.esc("<script>") == "&lt;script&gt;"
    end
  end
end
