defmodule Engram.Workers.ExportExpirySweepTest do
  @moduledoc """
  #859: an account export is a complete archive of a user's personal data.
  Expired exports (past the 7-day download window) previously persisted in
  S3 indefinitely; the sweep was only ever a TODO comment in AccountExport
  ("Task 15"). GDPR-retention bug, not hygiene.

  Failure semantics under test: a row flips :expired BEFORE its blobs are
  deleted (mint_download_url gates on :ready, so a half-deleted archive is
  never downloadable), failed/malformed keys are RETAINED on the row and
  retried by the next run, and one export's crash never blocks the rest.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Accounts.Export.Schema
  alias Engram.Storage.InMemory
  alias Engram.Workers.ExportExpirySweep

  defmodule FlakyAdapter do
    @moduledoc false
    def delete(key) do
      cond do
        key in Application.get_env(:engram, :test_raise_keys, []) ->
          raise "kaboom: #{key}"

        key in Application.get_env(:engram, :test_fail_keys, []) ->
          {:error, :signature_mismatch}

        true ->
          InMemory.delete(key)
      end
    end
  end

  setup do
    on_exit(fn ->
      Application.put_env(:engram, :storage, InMemory)
      Application.delete_env(:engram, :test_fail_keys)
      Application.delete_env(:engram, :test_raise_keys)
    end)

    %{user: insert(:user)}
  end

  defp insert_export!(user, attrs) do
    defaults = %{
      user_id: user.id,
      status: :ready,
      reason: :user_request,
      s3_keys: [],
      ready_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
    }

    %Schema{}
    |> Schema.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!(skip_tenant_check: true)
  end

  defp put_blob!(key) do
    :ok = InMemory.put(key, "zip-bytes")
    key
  end

  defp reload!(export), do: Repo.get!(Schema, export.id, skip_tenant_check: true)

  test "deletes blobs and expires rows past expires_at", %{user: user} do
    k1 = put_blob!("exports/#{user.id}/part-1.zip")
    k2 = put_blob!("exports/#{user.id}/part-2.zip")

    export =
      insert_export!(user, %{
        s3_keys: [%{"key" => k1}, %{"key" => k2}],
        expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

    assert :ok = perform_job(ExportExpirySweep, %{})

    refute InMemory.exists?(k1)
    refute InMemory.exists?(k2)

    row = reload!(export)
    assert row.status == :expired
    assert row.s3_keys == []
  end

  test "leaves unexpired ready exports untouched", %{user: user} do
    k = put_blob!("exports/#{user.id}/live.zip")

    export =
      insert_export!(user, %{
        s3_keys: [%{"key" => k}],
        expires_at: DateTime.add(DateTime.utc_now(), 3, :day)
      })

    assert :ok = perform_job(ExportExpirySweep, %{})

    assert InMemory.exists?(k)
    assert reload!(export).status == :ready
  end

  test "ignores non-ready rows with no retained keys", %{user: user} do
    export =
      insert_export!(user, %{
        status: :failed,
        error_reason: "boom",
        expires_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    assert :ok = perform_job(ExportExpirySweep, %{})
    assert reload!(export).status == :failed
  end

  test "partial delete failure: row flips :expired, failed key retained and retried",
       %{user: user} do
    k_ok = put_blob!("exports/#{user.id}/ok.zip")
    k_bad = put_blob!("exports/#{user.id}/bad.zip")
    Application.put_env(:engram, :storage, FlakyAdapter)
    Application.put_env(:engram, :test_fail_keys, [k_bad])

    export =
      insert_export!(user, %{
        s3_keys: [%{"key" => k_ok}, %{"key" => k_bad}],
        expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

    assert :ok = perform_job(ExportExpirySweep, %{})

    refute InMemory.exists?(k_ok)
    assert InMemory.exists?(k_bad)

    row = reload!(export)
    # :expired even though a key survives: mint_download_url gates on
    # :ready, so the half-deleted archive is never offered for download.
    assert row.status == :expired
    assert row.s3_keys == [%{"key" => k_bad}]

    # Next run with the failure cleared reaps the remainder.
    Application.put_env(:engram, :test_fail_keys, [])
    assert :ok = perform_job(ExportExpirySweep, %{})
    refute InMemory.exists?(k_bad)
    assert reload!(export).s3_keys == []
  end

  test "malformed s3_keys entry (no key) is retained + never silently orphaned",
       %{user: user} do
    export =
      insert_export!(user, %{
        s3_keys: [%{"part" => 1}],
        expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

    assert :ok = perform_job(ExportExpirySweep, %{})

    row = reload!(export)
    assert row.status == :expired
    assert row.s3_keys == [%{"part" => 1}]
  end

  test "one export raising does not block the rest", %{user: user} do
    k_boom = put_blob!("exports/#{user.id}/boom.zip")
    k_fine = put_blob!("exports/#{user.id}/fine.zip")
    Application.put_env(:engram, :storage, FlakyAdapter)
    Application.put_env(:engram, :test_raise_keys, [k_boom])

    _boom =
      insert_export!(user, %{
        s3_keys: [%{"key" => k_boom}],
        expires_at: DateTime.add(DateTime.utc_now(), -2, :hour)
      })

    fine =
      insert_export!(user, %{
        s3_keys: [%{"key" => k_fine}],
        expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

    assert :ok = perform_job(ExportExpirySweep, %{})

    refute InMemory.exists?(k_fine)
    assert reload!(fine).status == :expired
  end
end
