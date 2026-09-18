defmodule Engram.Crypto.AadRebindRlsTest do
  @moduledoc """
  Pins the AAD rebind against an ENFORCED row-level security policy.

  ## What breaks

  `do_rebind/1` opens a bare `Repo.transaction`, so nothing inside it carries a
  tenant. Every tenant-owned read beneath it is therefore filtered to nothing
  under a role the policy applies to:

    * `rebind_user_notes/1` selects the user's legacy `notes` — returns `[]`
    * `rebind_user_vaults/1` selects the user's legacy `vaults` — returns `[]`
    * `rebind_user_attachments/1` counts legacy `attachments` — returns 0

  With all three empty and the DEK wrap already v2, `rebind_locked_user/1`
  concludes nothing changed and reports **`:skipped`** for a user who still has
  legacy rows. The operator drain log then says the fleet is rebound while
  legacy envelopes remain, and the next drain skips them again for the same
  reason — the failure is stable, not transient.

  `rebind_vault/2` is the one loud site: its `{1, _} = ... update_all` hard
  match raises on a filtered write instead of silently reporting `{0, nil}`.
  This file does not exercise it, because a vault created through
  `Vaults.register_vault/3` is born v2 and never matches the legacy filter.

  ## No leaked tenant rescues this

  Unlike `Engram.Accounts.LifecycleRlsTest`, nothing on this path sets a tenant
  that could leak forward into the enclosing transaction: `aad_rebind.ex` calls
  `with_tenant/2` nowhere, `Engram.Crypto` has no `with_tenant` at all, and
  `DekCache` touches no database. So the harness's own tenant clear is the only
  state that matters here. See trap 7 in
  `docs/context/rls-enforcement-testing-traps.md`.

  `Workers.BackfillCrdtState` — the other caller of the public
  `AadRebind.rebind_note/2` — already wraps it in `Repo.with_tenant/2`, so it
  is NOT affected and needs no change.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Crypto
  alias Engram.Crypto.AadRebind
  alias Engram.Crypto.DekCache
  alias Engram.Crypto.Envelope
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)

    # Through the real context so the vault is born AAD-bound (dek_version 2).
    # A legacy vault would hit `rebind_vault/2`'s `{1, _} =` match and raise,
    # which is a different failure from the silent one under test.
    {:ok, vault, _} =
      Engram.Vaults.register_vault(user, "Rebind RLS Vault", Ecto.UUID.generate())

    %{user: user, vault: vault, note: legacy_note!(user, vault)}
  end

  # A note whose every ciphertext column was written with the EMPTY AAD and
  # whose row is stamped dek_version = 1 — exactly what the rebind exists to
  # migrate. Mirrors the fixture in `aad_rebind_test.exs`.
  defp legacy_note!(user, vault) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)

    {content_ct, content_n} = Envelope.encrypt("legacy body", dek)
    {title_ct, title_n} = Envelope.encrypt("legacy title", dek)
    {path_ct, path_n} = Envelope.encrypt("legacy/path.md", dek)
    {folder_ct, folder_n} = Envelope.encrypt("legacy", dek)
    {tags_ct, tags_n} = Envelope.encrypt(:erlang.term_to_binary(["t1"]), dek)

    fields = %{
      content_hash: "h",
      seq: 1,
      mtime: 0.0,
      user_id: user.id,
      vault_id: vault.id,
      content_ciphertext: content_ct,
      content_nonce: content_n,
      title_ciphertext: title_ct,
      title_nonce: title_n,
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Crypto.hmac_field(filter_key, "legacy/path.md"),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Crypto.hmac_field(filter_key, "legacy"),
      tags_ciphertext: tags_ct,
      tags_nonce: tags_n,
      tags_hmac: [Crypto.hmac_field(filter_key, "t1")],
      dek_version: 1
    }

    note =
      %Note{}
      |> Ecto.Changeset.cast(fields, Map.keys(fields))
      |> Repo.insert!(skip_tenant_check: true)

    # Guard the fixture itself: if this ever lands v2, every assertion below
    # would pass for the wrong reason.
    assert note.dek_version == 1
    note
  end

  describe "rebind_user/1 under enforced RLS" do
    # CONTROL. Without it, a green file cannot distinguish "the rebind is
    # correctly scoped" from "the role drop never engaged".
    test "control: the dropped role sees none of the user's legacy rows", %{user: user} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 [[n]] =
                   Repo.query!("SELECT count(*) FROM notes WHERE user_id = $1", [
                     Ecto.UUID.dump!(user.id)
                   ]).rows

                 n
               end)
    end

    test "rebinds the legacy note instead of reporting :skipped", %{user: user, note: note} do
      note_id = note.id

      # Committing harness: the claim is about what the rebind PERSISTED onto
      # the row, and a rollback would discard it and pass against a completely
      # unscoped implementation.
      result = as_prod_role_committing(fn -> AadRebind.rebind_user(user.id) end)

      # Unscoped, the notes select returns [], so nothing is counted as rebound
      # and the user is reported `:skipped` with legacy rows still in place.
      assert result == :ok

      reloaded = Repo.get!(Note, note_id, skip_tenant_check: true)
      assert reloaded.dek_version == Crypto.row_version_aad_bound()
    end
  end
end
