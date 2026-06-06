defmodule Engram.Accounts.Export.SchemaTest do
  use Engram.DataCase, async: true

  alias Engram.Accounts.Export.Schema
  alias Engram.Repo

  import Engram.Factory

  test "insert + read happy path" do
    user = insert(:user)

    {:ok, e} =
      %Schema{}
      |> Schema.changeset(%{user_id: user.id, status: :pending, reason: :user_request})
      |> Repo.insert(skip_tenant_check: true)

    reloaded = Repo.get!(Schema, e.id, skip_tenant_check: true)
    assert reloaded.status == :pending
    assert reloaded.reason == :user_request
    assert reloaded.s3_keys == []
  end

  test "partial unique index blocks second pending row for same user" do
    user = insert(:user)

    %Schema{}
    |> Schema.changeset(%{user_id: user.id, status: :pending, reason: :user_request})
    |> Repo.insert!(skip_tenant_check: true)

    # The changeset declares `unique_constraint(:user_id,
    # name: :account_exports_one_active_per_user)`, so the second insert
    # surfaces as a changeset error (caught + translated to
    # `{:error, :already_running}` by Export.request/1) rather than a raw
    # DB-level Ecto.ConstraintError.
    {:error, %Ecto.Changeset{errors: errors, valid?: false}} =
      %Schema{}
      |> Schema.changeset(%{user_id: user.id, status: :running, reason: :user_request})
      |> Repo.insert(skip_tenant_check: true)

    assert {_, opts} = errors[:user_id]
    assert Keyword.get(opts, :constraint) == :unique
  end

  test "cascade deletes when user is deleted" do
    user = insert(:user)

    {:ok, _e} =
      %Schema{}
      |> Schema.changeset(%{user_id: user.id, status: :pending, reason: :user_request})
      |> Repo.insert(skip_tenant_check: true)

    Repo.delete!(user, skip_tenant_check: true)
    assert Repo.aggregate(Schema, :count) == 0
  end
end
