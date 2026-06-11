defmodule Engram.Workers.AccountExportTest do
  @moduledoc """
  Happy-path tests for `Engram.Workers.AccountExport` (Task 12).

  These tests exercise the worker against the real `Engram.Storage.InMemory`
  adapter — same module used in dev/test for every other storage call — so
  the multipart calls are run for real rather than mocked. Tests that care
  about specific multipart interactions can swap in `Engram.MockStorage`
  via Mox; the happy path here just asserts the row + S3 sink end state.

  Decryption (Task 13), 10 GB part split + error paths (Task 14), and
  the export-ready email (Task 16) are explicitly out of scope here and
  noted at each assertion.
  """

  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.Factory

  alias Engram.Accounts.Export
  alias Engram.Accounts.Export.Schema
  alias Engram.Repo
  alias Engram.Storage.InMemory
  alias Engram.Workers.AccountExport

  defp as_pro(user) do
    insert(:subscription, user: user, tier: "pro", status: "active")
    user
  end

  setup do
    # Tests use the default InMemory adapter (config/test.exs). Wipe ETS
    # so the per-test storage sink doesn't carry state across tests.
    InMemory.ensure_table()
    :ets.delete_all_objects(:engram_test_storage_in_memory)

    case :ets.whereis(:engram_test_storage_in_memory_multipart) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:engram_test_storage_in_memory_multipart)
    end

    :ok
  end

  describe "perform/1 happy path" do
    test "streams a vault to S3 multipart and marks the export :ready" do
      user = insert(:user) |> as_pro()
      vault = insert(:vault, user: user)
      _note = insert(:note, user: user, vault: vault)
      _attachment = insert(:attachment, user: user, vault: vault, size_bytes: 1024)

      {:ok, export} = Export.request(user)

      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)
      assert reloaded.status == :ready
      assert is_integer(reloaded.size_bytes)
      assert reloaded.size_bytes > 0
      assert reloaded.expires_at
      assert reloaded.ready_at

      # expires_at is ~7 days from ready_at
      diff = DateTime.diff(reloaded.expires_at, reloaded.ready_at, :second)
      assert diff in (6 * 86_400)..(8 * 86_400)

      # s3_keys are stored as plain maps with the documented shape
      assert is_list(reloaded.s3_keys)
      assert reloaded.s3_keys != []

      Enum.each(reloaded.s3_keys, fn entry ->
        assert is_binary(entry["key"])
        assert is_integer(entry["part"])
        assert is_integer(entry["of"])
        assert is_integer(entry["size_bytes"])
        assert is_binary(entry["vault_id"])
        assert is_binary(entry["vault_name"])
      end)

      # The S3 sink actually has the blob.
      [%{"key" => key, "size_bytes" => size}] = reloaded.s3_keys
      assert {:ok, body} = InMemory.get(key)
      assert byte_size(body) == size
    end

    test "key encodes user_id, export_id, and vault slug" do
      user = insert(:user) |> as_pro()
      vault = insert(:vault, user: user)
      _note = insert(:note, user: user, vault: vault)

      {:ok, export} = Export.request(user)
      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)

      Enum.each(reloaded.s3_keys, fn %{"key" => key, "vault_name" => name} ->
        assert String.contains?(key, "exports/#{user.id}/")
        assert String.contains?(key, "#{export.id}/")
        assert String.contains?(key, vault.slug)
        # Until Task 13 wires DEK-decrypt, vault_name mirrors the slug.
        assert name == vault.slug
      end)
    end

    test "multi-vault user: one s3 key per vault" do
      user = insert(:user) |> as_pro()
      v1 = insert(:vault, user: user)
      v2 = insert(:vault, user: user)
      _ = insert(:note, user: user, vault: v1)
      _ = insert(:note, user: user, vault: v2)

      {:ok, export} = Export.request(user)
      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)
      vault_ids = reloaded.s3_keys |> Enum.map(& &1["vault_id"]) |> Enum.sort()
      assert vault_ids == Enum.sort([v1.id, v2.id])
    end

    test "user with no vaults: marks :ready with empty s3_keys" do
      user = insert(:user) |> as_pro()
      {:ok, export} = Export.request(user)

      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)
      assert reloaded.status == :ready
      assert reloaded.s3_keys == []
      assert reloaded.size_bytes == 0
    end

    test "missing export row: noop, does not crash" do
      assert :ok =
               perform_job(AccountExport, %{"export_id" => "00000000-0000-0000-0000-000999999999"})
    end
  end

  describe "perform/1 status transitions" do
    test "pending → running → ready" do
      user = insert(:user) |> as_pro()
      _vault = insert(:vault, user: user)

      {:ok, export} = Export.request(user)
      assert export.status == :pending

      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      assert %Schema{status: :ready} = Repo.reload!(export)
    end
  end
end
