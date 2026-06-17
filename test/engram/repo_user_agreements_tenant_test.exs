defmodule Engram.RepoUserAgreementsTenantTest do
  use Engram.DataCase, async: true

  test "querying user_agreements without with_tenant raises TenantError" do
    assert_raise Engram.TenantError, fn ->
      Engram.Repo.all(Engram.Onboarding.Agreement)
    end
  end

  test "querying user_agreements inside with_tenant succeeds" do
    user = insert(:user)

    result =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.all(Engram.Onboarding.Agreement)
      end)

    assert result == {:ok, []}
  end
end
