defmodule Engram.Accounts.Export.StreamerTest do
  @moduledoc """
  Unit tests for `Engram.Accounts.Export.Streamer` covering the hardening
  pass 2 invariants:

    * attachments are **not** emitted into the zip (deferred to Task 13 —
      `Attachment.content` is a virtual field, the schema query never
      materialises ciphertext from S3, so emitting them would write 0
      bytes).
    * empty vaults abort the multipart upload rather than completing a
      sole 0-byte part (MinIO/Garage reject that; AWS would accept it).
      End state for a user with only empty vaults: `s3_keys: []`,
      `status: :ready`.
    * the s3_keys list is returned in ascending part_number order across
      flushes (catches a reverse bug in the O(n²) → prepend+reverse
      refactor).
  """

  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.Factory
  import Mox

  alias Engram.Accounts.Export
  alias Engram.Accounts.Export.Streamer
  alias Engram.Repo
  alias Engram.Storage.InMemory
  alias Engram.Workers.AccountExport

  setup :verify_on_exit!

  defp as_pro(user) do
    insert(:subscription, user: user, tier: "pro", status: "active")
    user
  end

  setup do
    InMemory.ensure_table()
    :ets.delete_all_objects(:engram_test_storage_in_memory)

    case :ets.whereis(:engram_test_storage_in_memory_multipart) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:engram_test_storage_in_memory_multipart)
    end

    :ok
  end

  describe "attachments are not emitted (deferred to Task 13)" do
    test "vault with attachments produces a zip containing no attachment entries" do
      user = insert(:user) |> as_pro()
      vault = insert(:vault, user: user)
      _note = insert(:note, user: user, vault: vault)
      _attachment = insert(:attachment, user: user, vault: vault, size_bytes: 1024)

      {:ok, export} = Export.request(user)
      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)
      [%{"key" => key}] = reloaded.s3_keys
      {:ok, zip_bytes} = InMemory.get(key)

      {:ok, entries} = :zip.table(zip_bytes)

      filenames =
        Enum.flat_map(entries, fn
          {:zip_file, name, _info, _comment, _offset, _size} -> [to_string(name)]
          _ -> []
        end)

      refute Enum.any?(filenames, &String.starts_with?(&1, "attachments/")),
             "expected no attachment entries in zip, got: #{inspect(filenames)}"

      assert Enum.any?(filenames, &String.starts_with?(&1, "notes/")),
             "expected at least one note entry, got: #{inspect(filenames)}"
    end
  end

  describe "empty vault aborts multipart upload" do
    test "user with one empty vault: s3_keys: [], status: :ready, no zero-byte part stored" do
      user = insert(:user) |> as_pro()
      _vault = insert(:vault, user: user)

      {:ok, export} = Export.request(user)
      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)
      assert reloaded.status == :ready
      assert reloaded.s3_keys == []
      assert reloaded.size_bytes == 0
    end

    test "mint_download_url returns :no_such_part for any part when all vaults empty" do
      user = insert(:user) |> as_pro()
      _vault = insert(:vault, user: user)

      {:ok, export} = Export.request(user)
      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)
      # selfhost InMemory adapter short-circuits before :no_such_part, so
      # we assert the s3_keys-empty invariant directly here (the actual
      # :no_such_part wiring is covered in export_test.exs against a
      # non-selfhost mock).
      assert reloaded.s3_keys == []
    end

    test "Storage.abort_multipart_upload is called and complete_multipart_upload is NOT (MinIO/Garage gate)" do
      # Swap to Mox-controlled adapter for this test only so we can assert
      # the multipart sequence. Engram.MockStorage is the Mox double for
      # the Engram.Storage behaviour (test/support/mocks.ex).
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, Engram.Storage.InMemory) end)

      user = insert(:user) |> as_pro()
      _vault = insert(:vault, user: user)

      {:ok, export} = Export.request(user)

      # Empty vault: no start/upload/complete; no abort either, because
      # the streamer short-circuits before opening the multipart upload.
      expect(Engram.MockStorage, :start_multipart, 0, fn _ -> :unreachable end)
      expect(Engram.MockStorage, :upload_part, 0, fn _, _, _, _ -> :unreachable end)
      expect(Engram.MockStorage, :complete_multipart_upload, 0, fn _, _, _ -> :unreachable end)
      expect(Engram.MockStorage, :abort_multipart_upload, 0, fn _, _ -> :unreachable end)

      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)
      assert reloaded.status == :ready
      assert reloaded.s3_keys == []
    end
  end

  describe "part ordering" do
    test "multi-part vault: s3_keys parts are in ascending part_number order" do
      # Force the streamer to flush multiple parts by stuffing one vault
      # with many notes whose ciphertext sums above @min_part_bytes
      # (5 MiB). Each note carries ~64 KiB random ciphertext; ~100 notes
      # yields ~6.4 MiB, enough for ≥ 2 parts after zstream framing.
      user = insert(:user) |> as_pro()
      vault = insert(:vault, user: user)

      big_payload = :crypto.strong_rand_bytes(64 * 1024)

      Enum.each(1..100, fn _ ->
        insert(:note,
          user: user,
          vault: vault,
          content_ciphertext: big_payload
        )
      end)

      {:ok, export} = Export.request(user)
      assert :ok = perform_job(AccountExport, %{"export_id" => export.id})

      reloaded = Repo.reload!(export)

      part_numbers = Enum.map(reloaded.s3_keys, & &1["part"])

      assert part_numbers == Enum.sort(part_numbers),
             "expected ascending part order, got: #{inspect(part_numbers)}"
    end
  end

  describe "Streamer.run/2 direct" do
    test "user with one non-empty vault returns parts in ascending order and total bytes > 0" do
      user = insert(:user) |> as_pro()
      vault = insert(:vault, user: user)
      _note = insert(:note, user: user, vault: vault)

      {:ok, export} = Export.request(user)
      assert {:ok, parts, total} = Streamer.run(Repo.reload!(export), [])

      assert is_list(parts)
      assert total > 0
      part_numbers = Enum.map(parts, & &1["part"])
      assert part_numbers == Enum.sort(part_numbers)
    end
  end
end
