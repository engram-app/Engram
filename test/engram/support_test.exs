defmodule Engram.SupportTest do
  use Engram.DataCase, async: true
  alias Engram.Support
  alias Engram.Support.IssueReport

  setup do
    user = Engram.Factory.insert(:user)
    {:ok, user: user}
  end

  test "create_report/3 inserts a report scoped to the user", %{user: user} do
    params = %{
      "description" => "sync is broken",
      "surface" => "plugin",
      "app_version" => "1.9.24"
    }

    meta = %{vault_id: "vault-123", device_fingerprint: "abc123def456"}

    assert {:ok, %IssueReport{} = report} = Support.create_report(user, params, meta)
    assert report.user_id == user.id
    assert report.surface == "plugin"
    assert report.description == "sync is broken"
    assert report.vault_id == "vault-123"
    assert report.device_fingerprint == "abc123def456"
    assert report.status == "open"
    assert Engram.Repo.get(IssueReport, report.id)
  end

  test "create_report/3 rejects an unknown surface", %{user: user} do
    params = %{"description" => "x", "surface" => "carrier-pigeon", "app_version" => "1"}

    assert {:error, changeset} =
             Support.create_report(user, params, %{vault_id: nil, device_fingerprint: "z"})

    assert "is invalid" in errors_on(changeset).surface
  end

  test "create_report/3 rejects an over-long description", %{user: user} do
    params = %{
      "description" => String.duplicate("a", 5001),
      "surface" => "web",
      "app_version" => "1"
    }

    assert {:error, changeset} =
             Support.create_report(user, params, %{vault_id: nil, device_fingerprint: "z"})

    assert Keyword.has_key?(changeset.errors, :description)
  end
end
