defmodule EngramWeb.McpLegalNoticeTest do
  use Engram.DataCase, async: false

  alias Engram.LegalFixtures
  alias EngramWeb.McpController

  setup do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    LegalFixtures.insert_version(version: "2026-05-19")
    LegalFixtures.insert_version(document: "privacy_policy", version: "2026-05-19")
    LegalFixtures.reset_version_cache()

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev)
      LegalFixtures.reset_version_cache()
    end)

    user = insert(:user)
    {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-19", "h", "2026-05-19", "h", %{})
    # A stub on the no-transaction path, so only the legal note is under test.
    tool = %{name: "search_notes", handler: fn _user, _vault, _args -> {:ok, "result"} end}
    %{user: user, tool: tool}
  end

  defp text(tool, user) do
    {{:ok, %{"content" => [%{"text" => text}]}}, :ok, _} =
      McpController.run_tool_handler(tool, user, nil, %{})

    text
  end

  test "a pending legal change is appended once a day, not on every call", %{
    user: user,
    tool: tool
  } do
    LegalFixtures.insert_version(
      document: "privacy_policy",
      version: "2026-10-12",
      material: false,
      effective_date: ~D[2099-11-11],
      changelog: "Analytics linked to your account."
    )

    LegalFixtures.reset_version_cache()

    first = text(tool, user)
    assert first =~ "Engram's Privacy Policy has an update, effective November 11, 2099"
    assert first =~ "Analytics linked to your account."
    assert first =~ "https://engram.page/privacy"
    refute first =~ "accept"

    refute text(tool, user) =~ "Privacy Policy"
  end

  test "a material change tells the user to accept it", %{user: user, tool: tool} do
    LegalFixtures.insert_version(
      version: "2026-10-12",
      material: true,
      effective_date: ~D[2099-11-11]
    )

    LegalFixtures.reset_version_cache()

    assert text(tool, user) =~ "accept it at https://app.engram.page/onboard/agreement"
  end

  test "nothing is appended without a pending change", %{user: user, tool: tool} do
    refute text(tool, user) =~ "Engram's"
  end
end
