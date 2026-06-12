defmodule Engram.Onboarding.ActionTest do
  use Engram.DataCase, async: true

  alias Engram.Onboarding.Action

  # synthetic uuid; not persisted, no FK enforcement on changeset alone
  @user_id "00000000-0000-0000-0000-000000012345"

  test "accepts every enum value" do
    for action <- [
          "tour_offered_taken",
          "tour_offered_skipped",
          "tour_completed",
          "first_vault_created",
          "plugin_connected",
          "ai_connected"
        ] do
      assert Action.changeset(%Action{}, %{user_id: @user_id, action: action}).valid?
    end
  end

  test "rejects unknown action" do
    cs = Action.changeset(%Action{}, %{user_id: @user_id, action: "bogus"})
    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:action]
  end

  test "requires user_id and action" do
    cs = Action.changeset(%Action{}, %{})
    refute cs.valid?
    assert cs.errors[:user_id]
    assert cs.errors[:action]
  end

  describe "dismissed:<slug> variant" do
    test "accepts a well-formed dismissed:<slug> action" do
      cs =
        Action.changeset(
          %Action{},
          %{user_id: @user_id, action: "dismissed:claude"}
        )

      assert cs.valid?
    end

    test "accepts every slug shape used by the frontend catalog" do
      slugs =
        ~w(claude cursor claude_code chatgpt grok mistral open_webui lobechat windsurf cline continue opencode github_copilot other_mcp install_obsidian_plugin)

      for slug <- slugs do
        cs =
          Action.changeset(
            %Action{},
            %{user_id: @user_id, action: "dismissed:" <> slug}
          )

        assert cs.valid?, "expected dismissed:#{slug} to be valid"
      end
    end

    test "rejects dismissed:<slug> with uppercase, leading number, dashes, or empty slug" do
      for bad <- [
            "dismissed:Claude",
            "dismissed:1claude",
            "dismissed:claude-desktop",
            "dismissed:",
            "dismissed: claude"
          ] do
        cs =
          Action.changeset(
            %Action{},
            %{user_id: @user_id, action: bad}
          )

        refute cs.valid?, "expected #{inspect(bad)} to be invalid"
      end
    end

    test "still rejects unknown plain (non-dismissed) actions" do
      cs =
        Action.changeset(
          %Action{},
          %{user_id: @user_id, action: "not_a_real_action"}
        )

      refute cs.valid?
    end

    test "rejects dismissed:<slug> longer than 48 characters" do
      long_slug = String.duplicate("a", 49)

      cs =
        Action.changeset(
          %Action{},
          %{user_id: @user_id, action: "dismissed:" <> long_slug}
        )

      refute cs.valid?
    end

    test "accepts dismissed:<slug> exactly 48 characters" do
      slug = String.duplicate("a", 48)

      cs =
        Action.changeset(
          %Action{},
          %{user_id: @user_id, action: "dismissed:" <> slug}
        )

      assert cs.valid?
    end
  end
end
