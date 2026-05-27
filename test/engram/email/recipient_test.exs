defmodule Engram.Email.RecipientTest do
  use ExUnit.Case, async: true

  alias Engram.Email.Recipient

  describe "new/2" do
    test "builds a recipient and trims whitespace" do
      assert {:ok, %Recipient{email: "ada@example.com", name: "Ada"}} =
               Recipient.new("  ada@example.com ", "  Ada ")
    end

    test "rejects a value that is not an email address" do
      assert {:error, :invalid_email} = Recipient.new("not-an-email", "Ada")
      assert {:error, :invalid_email} = Recipient.new("", "Ada")
    end

    test "allows a blank name" do
      assert {:ok, %Recipient{email: "ada@example.com", name: ""}} =
               Recipient.new("ada@example.com", "")
    end
  end
end
