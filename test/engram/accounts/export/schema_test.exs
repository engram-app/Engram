defmodule Engram.Accounts.Export.SchemaTest do
  use Engram.DataCase, async: true

  import Engram.Factory

  alias Engram.Accounts.Export.Schema
  alias Engram.Repo

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
    assert Repo.aggregate(Schema, :count, skip_tenant_check: true) == 0
  end

  # error_reason is varchar(255) and the worker writes an inspected error term.
  # A longer reason raised on the UPDATE meant to record the failure, so the
  # export never reached :failed. Postgres counts codepoints, so a grapheme cut
  # ("e" + combining acute is one grapheme, two codepoints) would still overflow.
  test "an over-long error_reason is truncated to 255 codepoints and the export fails" do
    user = insert(:user)

    export =
      %Schema{}
      |> Schema.changeset(%{user_id: user.id, status: :running, reason: :user_request})
      |> Repo.insert!(skip_tenant_check: true)

    huge = String.duplicate("e\u0301", 10_000)

    {:ok, _} =
      export
      |> Schema.changeset(%{status: :failed, error_reason: huge})
      |> Repo.update(skip_tenant_check: true)

    reloaded = Repo.get!(Schema, export.id, skip_tenant_check: true)
    assert reloaded.status == :failed
    assert length(String.codepoints(reloaded.error_reason)) == 255
    assert String.valid?(reloaded.error_reason)
  end

  test "a short error_reason is stored as is" do
    user = insert(:user)

    {:ok, e} =
      %Schema{}
      |> Schema.changeset(%{
        user_id: user.id,
        status: :failed,
        reason: :user_request,
        error_reason: ":timeout"
      })
      |> Repo.insert(skip_tenant_check: true)

    assert e.error_reason == ":timeout"
  end

  test "clearing error_reason to nil is allowed" do
    user = insert(:user)

    {:ok, e} =
      %Schema{}
      |> Schema.changeset(%{
        user_id: user.id,
        status: :failed,
        reason: :user_request,
        error_reason: ":timeout"
      })
      |> Repo.insert(skip_tenant_check: true)

    {:ok, cleared} =
      e
      |> Schema.changeset(%{error_reason: nil})
      |> Repo.update(skip_tenant_check: true)

    assert is_nil(cleared.error_reason)
  end
end
