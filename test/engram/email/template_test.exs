defmodule Engram.Email.TemplateTest do
  use ExUnit.Case, async: true

  alias Engram.Email.Template

  describe "render/1" do
    test "wraps a body in the brand layout and returns {:ok, html}" do
      assert {:ok, html} = Template.render("<mj-text>Hello there</mj-text>")
      assert html =~ "Engram"
      assert html =~ "Hello there"
    end

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
