defmodule Mix.Tasks.Engram.Email.BroadcastTest do
  use ExUnit.Case, async: true

  alias Engram.Email.Recipient
  alias Mix.Tasks.Engram.Email.Broadcast, as: Task

  describe "parse_csv/1" do
    test "parses email,name rows into validated recipients and skips the header" do
      csv = """
      email,name
      ada@example.com,Ada Lovelace
      grace@example.com,Grace Hopper
      """

      assert Task.parse_csv(csv) == [
               %Recipient{email: "ada@example.com", name: "Ada Lovelace"},
               %Recipient{email: "grace@example.com", name: "Grace Hopper"}
             ]
    end

    test "trims whitespace and ignores blank lines" do
      csv = "email,name\n  bob@example.com ,  Bob \n\n"

      assert Task.parse_csv(csv) == [%Recipient{email: "bob@example.com", name: "Bob"}]
    end

    test "raises naming the line on a row with no comma" do
      csv = "email,name\nada@example.com,Ada\nbroken-row-no-comma\n"

      assert_raise Mix.Error, ~r/line 3/, fn -> Task.parse_csv(csv) end
    end

    test "raises naming the line on an invalid email" do
      csv = "email,name\nnot-an-email,Ada\n"

      assert_raise Mix.Error, ~r/invalid email on CSV line 2/, fn -> Task.parse_csv(csv) end
    end
  end

  describe "run/1 argument validation (before any send)" do
    test "raises when --csv is missing" do
      assert_raise Mix.Error, ~r/--csv is required/, fn ->
        Task.run(["--template", "og3"])
      end
    end

    test "raises on an unknown --template" do
      assert_raise Mix.Error, ~r/--template must be/, fn ->
        Task.run(["--template", "nope", "--csv", "x.csv"])
      end
    end

    test "raises when og1 is missing --checkout-url" do
      assert_raise Mix.Error, ~r/--checkout-url is required/, fn ->
        Task.run(["--template", "og1", "--csv", "x.csv"])
      end
    end

    test "raises when og2 is missing --portal-url" do
      assert_raise Mix.Error, ~r/--portal-url is required/, fn ->
        Task.run(["--template", "og2", "--csv", "x.csv", "--expiry-date", "June 1, 2027"])
      end
    end

    test "surfaces a clear error for a nonexistent CSV path" do
      assert_raise File.Error, fn ->
        Task.run(["--template", "og3", "--csv", "/no/such/file-#{System.unique_integer()}.csv"])
      end
    end
  end
end
