defmodule Engram.Workers.BackfillVaultSlugHmacTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Vaults
  alias Engram.Vaults.Vault
  alias Engram.Workers.BackfillVaultSlugHmac

  defp raw(vault_id),
    do: Repo.one!(from(v in Vault, where: v.id == ^vault_id), skip_tenant_check: true)

  # Rows minted before the expand release have a slug but no slug_hmac.
  defp strip(vault_id) do
    Repo.update_all(
      from(v in Vault, where: v.id == ^vault_id),
      [set: [slug_hmac: nil, slug_suffixed: false]],
      skip_tenant_check: true
    )
  end

  test "fills slug_hmac and slug_suffixed for rows that predate them" do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, plain, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
    {:ok, suffixed, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
    strip(plain.id)
    strip(suffixed.id)

    assert :ok = perform_job(BackfillVaultSlugHmac, %{})

    {:ok, filter_key} = Crypto.dek_filter_key(Repo.reload!(user))
    assert raw(plain.id).slug_hmac == Crypto.hmac_field(filter_key, "notes")
    refute raw(plain.id).slug_suffixed
    assert raw(suffixed.id).slug_hmac == Crypto.hmac_field(filter_key, suffixed.slug)
    assert raw(suffixed.id).slug_suffixed
  end

  test "is idempotent and leaves filled rows alone" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    before = raw(vault.id).slug_hmac

    assert :ok = perform_job(BackfillVaultSlugHmac, %{})
    assert :ok = perform_job(BackfillVaultSlugHmac, %{})
    assert raw(vault.id).slug_hmac == before
  end

  test "skips a user mid-rotation and fills them on a later run" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    strip(vault.id)

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [dek_rotation_locked_at: DateTime.utc_now()]
    )

    assert :ok = perform_job(BackfillVaultSlugHmac, %{})
    assert raw(vault.id).slug_hmac == nil

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [dek_rotation_locked_at: nil]
    )

    assert :ok = perform_job(BackfillVaultSlugHmac, %{})
    assert raw(vault.id).slug_hmac != nil
  end

  defp set_raw(vault_id, fields),
    do:
      Repo.update_all(from(v in Vault, where: v.id == ^vault_id), [set: fields],
        skip_tenant_check: true
      )

  defp id6(vault), do: String.slice(vault.id, -6, 6)

  test "rewrites a legacy -2 slug to the derivable id-suffix form" do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, first, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
    {:ok, legacy, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
    set_raw(legacy.id, slug: "notes-2", slug_hmac: nil, slug_suffixed: false)

    assert :ok = perform_job(BackfillVaultSlugHmac, %{})

    {:ok, filter_key} = Crypto.dek_filter_key(Repo.reload!(user))
    row = raw(legacy.id)
    assert row.slug == "notes-#{id6(legacy)}"
    assert row.slug_suffixed
    assert row.slug_hmac == Crypto.hmac_field(filter_key, row.slug)
    assert raw(first.id).slug == "notes"
  end

  test "rewrites an old-slugify slug to the base when no sibling holds it" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "My Vault", Ecto.UUID.generate())
    set_raw(vault.id, slug: "my_vault", slug_hmac: nil)

    assert :ok = perform_job(BackfillVaultSlugHmac, %{})

    row = raw(vault.id)
    assert row.slug == "my-vault"
    refute row.slug_suffixed
  end

  test "repairs a stale non-NULL slug_hmac left by a pre-expand rename" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    stale = raw(vault.id).slug_hmac
    # Old code renamed the vault: name + slug moved, slug_hmac did not.
    {:ok, _} = Vaults.update_vault(user, vault.id, %{name: "Job"})
    set_raw(vault.id, slug_hmac: stale)

    assert :ok = perform_job(BackfillVaultSlugHmac, %{})

    {:ok, filter_key} = Crypto.dek_filter_key(Repo.reload!(user))
    assert raw(vault.id).slug_hmac == Crypto.hmac_field(filter_key, "job")
  end

  test "reads the rotation lock fresh, not from a stale user struct" do
    user = insert(:user)
    {:ok, vault, _} = Vaults.register_vault(user, "Work", Ecto.UUID.generate())
    strip(vault.id)

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
      set: [dek_rotation_locked_at: DateTime.utc_now()]
    )

    # `user` still carries dek_rotation_locked_at: nil.
    assert {:error, :rotation_in_progress} = Vaults.backfill_slug_hmacs(user)
    assert raw(vault.id).slug_hmac == nil
  end

  test "is scheduled by the Oban cron" do
    {Oban.Plugins.Cron, opts} =
      Application.fetch_env!(:engram, Oban)[:plugins]
      |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

    assert Enum.any?(opts[:crontab], &match?({_, BackfillVaultSlugHmac}, &1))
  end
end
