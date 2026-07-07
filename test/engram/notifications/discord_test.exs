defmodule Engram.Notifications.DiscordTest do
  use ExUnit.Case, async: true
  alias Engram.Notifications.Discord
  alias Engram.Support.IssueReport

  defp report do
    %IssueReport{
      id: "00000000-0000-0000-0000-000000000001",
      user_id: "11111111-1111-1111-1111-111111111111",
      surface: "plugin",
      app_version: "1.9.24",
      description: "sync stalls on large notes",
      inserted_at: ~U[2026-07-07 18:00:00.000000Z]
    }
  end

  test "build_report_payload/2 carries user id, surface, and a query window" do
    %{content: content} = Discord.build_report_payload(report(), "todd@example.com")
    assert content =~ "plugin"
    assert content =~ "1.9.24"
    assert content =~ "todd@example.com"
    assert content =~ "11111111-1111-1111-1111-111111111111"
    assert content =~ "sync stalls on large notes"
    # +/- 10 min window around 18:00:00
    assert content =~ "2026-07-07T17:50:00"
    assert content =~ "2026-07-07T18:10:00"
  end

  test "build_report_payload/2 truncates a long description" do
    long = %{report() | description: String.duplicate("x", 3000)}
    %{content: content} = Discord.build_report_payload(long, "a@b.com")
    assert content =~ "…"
    assert String.length(content) < 2200
  end
end
