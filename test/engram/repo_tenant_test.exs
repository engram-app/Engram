defmodule Engram.RepoTenantTest do
  use Engram.DataCase, async: true

  describe "with_tenant/2" do
    test "tenant isolation — user B cannot see user A's notes" do
      user_a = insert(:user)
      user_b = insert(:user)

      # Insert a note as User A through the public upsert path so Phase B
      # ciphertext + hmac fields populate correctly. Direct `Note.changeset`
      # writes are unsafe post-B.3 — schema requires ciphertext/hmac/nonce.
      vault_a = insert(:vault, user: user_a)

      {:ok, _} =
        Engram.Notes.upsert_note(user_a, vault_a, %{
          "path" => "secret.md",
          "content" => "private",
          "mtime" => 1_000.0
        })

      # User B sees nothing
      {:ok, notes} =
        Repo.with_tenant(user_b.id, fn ->
          Repo.all(Note)
        end)

      assert notes == []

      # User A sees their own note
      {:ok, notes} =
        Repo.with_tenant(user_a.id, fn ->
          Repo.all(Note)
        end)

      assert length(notes) == 1
      hd_note = hd(notes)
      reloaded_user_a = Engram.Repo.get!(Engram.Accounts.User, user_a.id)
      {:ok, decrypted} = Engram.Crypto.maybe_decrypt_note_fields(hd_note, reloaded_user_a)
      assert decrypted.path == "secret.md"
    end

    test "returns the result of the function" do
      user = insert(:user)

      result =
        Repo.with_tenant(user.id, fn ->
          42
        end)

      assert {:ok, 42} = result
    end

    test "cleans up process dict after normal execution" do
      user = insert(:user)
      Repo.with_tenant(user.id, fn -> :ok end)
      assert Process.get(:engram_tenant) == nil
    end

    test "cleans up process dict after exception" do
      user = insert(:user)

      assert_raise RuntimeError, fn ->
        Repo.with_tenant(user.id, fn -> raise "boom" end)
      end

      assert Process.get(:engram_tenant) == nil
    end

    test "rejects non-integer tenant_id (SQL injection guard)" do
      assert_raise ArgumentError, ~r/tenant_id must be a positive integer/, fn ->
        Repo.with_tenant("1'; DROP TABLE notes; --", fn -> :ok end)
      end
    end

    test "rejects nil tenant_id" do
      assert_raise ArgumentError, ~r/tenant_id must be a positive integer/, fn ->
        Repo.with_tenant(nil, fn -> :ok end)
      end
    end
  end

  describe "prepare_query safety net" do
    test "raises TenantError when querying tenant table without context" do
      assert_raise Engram.TenantError, ~r/Tenant context not set/, fn ->
        Repo.all(Note)
      end
    end

    test "allows queries with skip_tenant_check option" do
      # This should not raise — used for admin/cron operations
      notes = Repo.all(Note, skip_tenant_check: true)
      assert notes == []
    end
  end
end
