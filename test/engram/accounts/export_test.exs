defmodule Engram.Accounts.ExportTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.Factory
  import Mox

  alias Engram.Accounts.Export
  alias Engram.Accounts.Export.Schema
  alias Engram.Repo

  setup :verify_on_exit!

  defp as_pro(user) do
    insert(:subscription, user: user, tier: "pro", status: "active")
    user
  end

  defp insert_export!(user, status, opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())
    s3_keys = Keyword.get(opts, :s3_keys, [])

    %Schema{
      user_id: user.id,
      status: status,
      reason: :user_request,
      s3_keys: s3_keys,
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

  describe "mint_download_url/2" do
    setup do
      prev_storage = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)

      on_exit(fn ->
        if is_nil(prev_storage),
          do: Application.delete_env(:engram, :storage),
          else: Application.put_env(:engram, :storage, prev_storage)
      end)

      # Default-stub callbacks unused by individual tests so existing
      # behaviour callbacks don't blow up if invoked indirectly.
      stub_with(Engram.MockStorage, Engram.Storage.InMemory)
      :ok
    end

    defp s3_key_entry(part, of, key \\ nil) do
      %{
        "key" => key || "exports/u/abc/v.part-#{part}of#{of}.zip",
        "part" => part,
        "of" => of,
        "size_bytes" => 100,
        "vault_id" => 1,
        "vault_name" => "main"
      }
    end

    test "saas → returns fresh 1h signed URL keyed by part" do
      user = insert(:user) |> as_pro()

      export =
        insert_export!(user, :ready,
          s3_keys: [s3_key_entry(1, 1, "exports/#{user.id}/abc/main.part-1of1.zip")]
        )

      expect(Engram.MockStorage, :selfhost?, fn -> false end)

      expect(Engram.MockStorage, :sign_url, fn key, opts ->
        assert key == "exports/#{user.id}/abc/main.part-1of1.zip"
        assert Keyword.get(opts, :ttl) == 3600
        "https://signed.example/" <> key <> "?sig=abc"
      end)

      assert {:ok, %{1 => url}} = Export.mint_download_url(export, 1)
      assert is_binary(url)
      assert url =~ "main.part-1of1.zip"
      assert url =~ "sig=abc"
    end

    test "fresh URL minted per call (no caching)" do
      user = insert(:user) |> as_pro()
      export = insert_export!(user, :ready, s3_keys: [s3_key_entry(1, 1)])

      expect(Engram.MockStorage, :selfhost?, 2, fn -> false end)

      expect(Engram.MockStorage, :sign_url, 2, fn _key, _opts ->
        # Each call returns a distinct URL → proves no caching at this layer.
        "https://signed.example/x?sig=#{System.unique_integer([:positive])}"
      end)

      {:ok, %{1 => u1}} = Export.mint_download_url(export, 1)
      {:ok, %{1 => u2}} = Export.mint_download_url(export, 1)
      assert u1 != u2
    end

    test "selfhost → {:error, :selfhost_uses_stream}" do
      user = insert(:user)
      export = insert_export!(user, :ready, s3_keys: [s3_key_entry(1, 1)])

      expect(Engram.MockStorage, :selfhost?, fn -> true end)

      assert {:error, :selfhost_uses_stream} = Export.mint_download_url(export, 1)
    end

    test "{:error, :no_such_part} when part index out of range" do
      user = insert(:user)
      export = insert_export!(user, :ready, s3_keys: [s3_key_entry(1, 1)])

      expect(Engram.MockStorage, :selfhost?, fn -> false end)

      assert {:error, :no_such_part} = Export.mint_download_url(export, 5)
    end

    test "non-:ready status → {:error, :not_ready}" do
      # Fresh user per iteration — `account_exports_one_active_per_user`
      # partial unique index forbids two pending/running per user.
      for status <- [:pending, :running, :failed, :expired] do
        user = insert(:user)
        export = insert_export!(user, status, s3_keys: [s3_key_entry(1, 1)])
        # No Storage expectations — status guard fires before any adapter call.
        assert {:error, :not_ready} = Export.mint_download_url(export, 1),
               "expected :not_ready for status #{inspect(status)}"
      end
    end

    test "multi-part export: returns URL only for requested part" do
      user = insert(:user) |> as_pro()

      export =
        insert_export!(user, :ready,
          s3_keys: [
            s3_key_entry(1, 3, "exports/#{user.id}/x/v.part-1of3.zip"),
            s3_key_entry(2, 3, "exports/#{user.id}/x/v.part-2of3.zip"),
            s3_key_entry(3, 3, "exports/#{user.id}/x/v.part-3of3.zip")
          ]
        )

      expect(Engram.MockStorage, :selfhost?, fn -> false end)

      expect(Engram.MockStorage, :sign_url, fn key, _opts ->
        assert key =~ "part-2of3"
        "https://signed.example/" <> key
      end)

      assert {:ok, %{2 => url}} = Export.mint_download_url(export, 2)
      assert url =~ "part-2of3"
    end
  end
end
