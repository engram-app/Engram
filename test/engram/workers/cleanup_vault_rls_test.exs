defmodule Engram.Workers.CleanupVaultRlsTest do
  @moduledoc """
  Pins vault hard-delete against an ENFORCED row-level security policy.

  ## What breaks

  `perform_cleanup/3` loads the vault with `Repo.get(Vault, vault_id,
  skip_tenant_check: true)`. Under RLS that read is FILTERED, not rejected, so
  it returns `nil` — and the very next clause treats `nil` as "vault was
  already cleaned up", logs at :debug, and returns `:ok`.

  So the job reports success, Oban records a completed run, and nothing is
  deleted. The notes, chunks, attachments and the vault row all survive, and
  the S3 blobs behind them are never collected. A user who asked for permanent
  deletion 30 days ago still has their data, and every observable says the
  cleanup ran.

  Even if the load were fixed in isolation, the four writes inside the
  transaction are filtered the same way: `delete_all` reports `{0, nil}`
  without error, and `Repo.delete!(vault)` — which carries no bypass at all —
  would raise `Ecto.StaleEntryError` on a filtered delete.

  ## Why `cleanup_vault_test.exs` passes today

  It has the right assertion already — "hard-deletes notes, attachments, and
  vault when soft-deleted" — and it passes regardless, because the suite
  connects as a Postgres superuser and a superuser bypasses RLS even under
  `FORCE`. This file is that assertion with the role dropped.

  The COMMITTING harness is required here: the whole claim is about rows being
  GONE afterwards, and the rolling-back variant would discard the deletes under
  test and pass against a completely unscoped implementation. See the warning
  on `Engram.RlsCase.as_prod_role/1`.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase
  import Mox

  alias Engram.Accounts
  alias Engram.Accounts.ApiKey
  alias Engram.Attachments.Attachment
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.CleanupVault

  setup :set_mox_from_context
  setup :verify_on_exit!

  # Qdrant stubbing is deliberately NOT in `setup`. `Bypass.expect/2` requires
  # at least one request to arrive, and the control test never calls Qdrant —
  # so a shared expectation failed it with "No HTTP request arrived at Bypass",
  # which is indistinguishable at a glance from the RLS harness failing to
  # engage. Only the test that actually reaches the sweep asks for it.
  defp stub_qdrant! do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
    end)

    :ok
  end

  setup do
    user = insert(:user)

    # Aged past the 30-day retention window, so `perform_cleanup/3` reaches the
    # hard-delete branch instead of snoozing on the age guard.
    vault =
      insert(:vault,
        user: user,
        deleted_at: DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)
      )

    note = insert(:note, user: user, vault: vault)
    attachment = insert(:attachment, user: user, vault: vault)

    %{user: user, vault: vault, note: note, attachment: attachment}
  end

  describe "perform_cleanup/3 under enforced RLS" do
    # CONTROL. Without it, a green file cannot distinguish "the delete is
    # correctly scoped" from "the role drop never engaged". The fixtures above
    # are written as the superuser, and anything routed through a
    # `with_tenant` leaves its SET LOCAL tenant behind in this sandbox
    # transaction — which is why the harness clears the tenant before dropping
    # the role.
    test "control: the dropped role cannot see the vault", %{vault: vault} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(v in Vault, where: v.id == ^vault.id, select: count(v.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "actually deletes the vault's rows", %{
      user: user,
      vault: vault,
      note: note,
      attachment: attachment
    } do
      stub_qdrant!()

      # Unscoped, this returns `:ok` having deleted nothing: the vault read is
      # filtered to nil and the job treats that as "already cleaned up".
      as_prod_role_committing(fn -> CleanupVault.perform_cleanup(vault.id, user.id) end)

      # Read back as the superuser — reading inside the dropped role would be
      # filtered too, and every assertion would pass while the rows survived.
      refute Repo.get(Note, note.id, skip_tenant_check: true)
      refute Repo.get(Attachment, attachment.id, skip_tenant_check: true)
      refute Repo.get(Vault, vault.id, skip_tenant_check: true)

      assert [] ==
               Repo.all(from(c in Chunk, where: c.vault_id == ^vault.id), skip_tenant_check: true)
    end
  end

  # An API key with no `api_key_vaults` rows is UNRESTRICTED
  # (`Vaults.accessible_vault_ids/1` returns `:all`). Hard-deleting a vault
  # deleted its mapping rows, so a key restricted to that vault alone silently
  # became a key to every vault the user owns. The key can trigger this itself:
  # `DELETE /api/vaults/:id` accepts API-key auth.
  describe "API keys restricted to the deleted vault" do
    defp restrict!(key, vault) do
      Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(vault.id)}
      ])
    end

    defp key_exists?(key), do: Repo.get(ApiKey, key.id, skip_tenant_check: true) != nil

    test "a key restricted to only that vault is revoked, not widened", %{
      user: user,
      vault: vault
    } do
      stub_qdrant!()
      {:ok, raw, key} = Accounts.create_api_key(user, "sole-vault")
      restrict!(key, vault)

      as_prod_role_committing(fn -> CleanupVault.perform_cleanup(vault.id, user.id) end)

      refute key_exists?(key)
      assert {:error, :invalid_key} = Accounts.validate_api_key(raw)
    end

    test "a key also restricted to another vault keeps only that vault", %{
      user: user,
      vault: vault
    } do
      stub_qdrant!()
      other = insert(:vault, user: user)
      {:ok, _raw, key} = Accounts.create_api_key(user, "two-vaults")
      restrict!(key, vault)
      restrict!(key, other)

      as_prod_role_committing(fn -> CleanupVault.perform_cleanup(vault.id, user.id) end)

      assert key_exists?(key)
      assert Engram.Vaults.accessible_vault_ids(key) == [other.id]
    end

    test "an unrestricted key is untouched", %{user: user, vault: vault} do
      stub_qdrant!()
      {:ok, _raw, key} = Accounts.create_api_key(user, "unrestricted")

      as_prod_role_committing(fn -> CleanupVault.perform_cleanup(vault.id, user.id) end)

      assert key_exists?(key)
    end
  end
end
