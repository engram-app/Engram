defmodule Engram.Accounts.ExportTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Accounts.Export
  alias Engram.Accounts.Export.Schema
  alias Engram.Repo

  import Engram.Factory

  defp as_pro(user) do
    insert(:subscription, user: user, tier: "pro", status: "active")
    user
  end

  defp insert_export!(user, status, opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    %Schema{
      user_id: user.id,
      status: status,
      reason: :user_request,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
    |> Repo.insert!(skip_tenant_check: true)
  end

  describe "request/1" do
    test "inserts pending row + enqueues worker" do
      user = insert(:user)
      {:ok, export} = Export.request(user)
      assert export.status == :pending
      assert export.user_id == user.id
      assert export.reason == :user_request

      assert [%Oban.Job{args: %{"export_id" => id}}] =
               all_enqueued(worker: Engram.Workers.AccountExport)

      assert id == export.id
    end

    test "free user past lifetime cap -> :lifetime_exceeded" do
      user = insert(:user)
      _spent = insert_export!(user, :ready)

      assert {:error, :lifetime_exceeded} = Export.request(user)
    end

    test "pro user inside 24h window -> :rate_exceeded" do
      user = insert(:user) |> as_pro()
      recent = DateTime.utc_now() |> DateTime.add(-1800, :second)
      _recent = insert_export!(user, :ready, inserted_at: recent)

      assert {:error, :rate_exceeded} = Export.request(user)
    end

    test "size estimate over cap -> :too_large" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      insert(:attachment,
        user: user,
        vault: vault,
        size_bytes: 2_000_000_000
      )

      assert {:error, :too_large} = Export.request(user)
    end

    test "failed exports do NOT burn lifetime quota" do
      user = insert(:user)
      _failed = insert_export!(user, :failed)

      assert {:ok, _} = Export.request(user)
    end

    test "second concurrent request -> :already_running via unique index" do
      user = insert(:user) |> as_pro()
      {:ok, _} = Export.request(user)
      assert {:error, :already_running} = Export.request(user)
    end
  end

  describe "list/2" do
    test "returns most-recent first within limit" do
      user = insert(:user)
      older_ts = DateTime.utc_now() |> DateTime.add(-7200, :second)
      newer_ts = DateTime.utc_now() |> DateTime.add(-600, :second)

      older = insert_export!(user, :ready, inserted_at: older_ts)
      newer = insert_export!(user, :ready, inserted_at: newer_ts)

      [first, second] = Export.list(user, 10)
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "respects limit" do
      user = insert(:user)

      for i <- 1..15 do
        insert_export!(user, :ready,
          inserted_at: DateTime.add(DateTime.utc_now(), -i * 60, :second)
        )
      end

      assert length(Export.list(user, 5)) == 5
    end

    test "scoped to caller — cross-user isolation" do
      a = insert(:user)
      b = insert(:user)
      _b_export = insert_export!(b, :ready)
      assert Export.list(a) == []
    end
  end

  describe "get/2" do
    test "returns {:ok, export} for owner" do
      user = insert(:user)
      e = insert_export!(user, :ready)
      assert {:ok, %Schema{id: id}} = Export.get(user, e.id)
      assert id == e.id
    end

    test "returns {:error, :not_found} for non-owner" do
      a = insert(:user)
      b = insert(:user)
      export = insert_export!(b, :ready)
      assert {:error, :not_found} = Export.get(a, export.id)
    end

    test "returns {:error, :not_found} for unknown id" do
      user = insert(:user)
      assert {:error, :not_found} = Export.get(user, 999_999_999)
    end
  end
end
