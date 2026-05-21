defmodule Engram.Vaults do
  @moduledoc """
  Vaults context — CRUD, registration, and default resolution for vaults.
  All write operations are tenant-scoped via Repo.with_tenant/2.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Repo
  alias Engram.Vaults.Vault

  # ── Create ─────────────────────────────────────────────────────────────────

  @doc """
  Creates a new vault for a user.

  - Enforces billing limit (max_vaults).
  - First vault is automatically set as default.
  - Generates a unique slug from the name.

  Returns {:ok, vault} or {:error, :vault_limit_reached} or {:error, changeset}.
  """
  def create_vault(user, attrs) do
    # Ensure user has a DEK before Phase B injection
    with {:ok, user} <- Engram.Crypto.ensure_user_dek(user) do
      Repo.with_tenant(user.id, fn ->
        current_count = count_vaults(user.id)

        case Billing.check_limit(user, :vaults_cap, current_count) do
          {:error, :limit_reached} ->
            {:error, :vault_limit_reached}

          :ok ->
            is_default = current_count == 0
            name = attrs[:name] || attrs["name"] || ""
            slug = unique_slug(user.id, slugify(name))
            vault_id = Engram.Crypto.next_row_id(:vaults)

            vault_attrs =
              attrs
              |> atomize_keys()
              |> inject_name_phase_b(user, vault_id)
              |> Map.merge(%{slug: slug, user_id: user.id, is_default: is_default})

            %Vault{id: vault_id}
            |> Vault.changeset(vault_attrs)
            |> Repo.insert()
            |> case do
              {:ok, v} ->
                emit_vault_count(user.id, :created)
                {:ok, decrypt_vault_if_needed(v, user)}

              other ->
                other
            end
        end
      end)
      |> unwrap_transaction()
    end
  end

  # Pricing v2 §J — telemetry-only per-account vault count. Emitted on every
  # vault create/delete so a downstream aggregator can spot Pro-as-team
  # accounts (15+ vaults) as Team-tier launch candidates.
  defp emit_vault_count(user_id, op) do
    count = count_vaults(user_id)

    :telemetry.execute(
      [:engram, :abuse, :vault_count],
      %{count: count},
      %{user_id: user_id, op: op}
    )

    :ok
  end

  # ── Register (idempotent) ───────────────────────────────────────────────────

  @doc """
  Registers a vault by client_id. Idempotent: returns the existing vault if
  a non-deleted vault with this client_id already exists for the user.

  Returns:
    {:ok, vault, :created}   — new vault was inserted
    {:ok, vault, :existing}  — matched an existing vault
    {:error, :vault_limit_reached}
  """
  def register_vault(user, name, client_id) do
    # Ensure user has a DEK before Phase B injection
    with {:ok, user} <- Engram.Crypto.ensure_user_dek(user) do
      result =
        Repo.with_tenant(user.id, fn ->
          existing = find_by_client_id(user.id, client_id)

          case existing do
            %Vault{} = vault ->
              {:ok, decrypt_vault_if_needed(vault, user), :existing}

            nil ->
              current_count = count_vaults(user.id)

              case Billing.check_limit(user, :vaults_cap, current_count) do
                {:error, :limit_reached} ->
                  {:error, :vault_limit_reached}

                :ok ->
                  is_default = current_count == 0
                  slug = unique_slug(user.id, slugify(name))
                  vault_id = Engram.Crypto.next_row_id(:vaults)

                  attrs = %{
                    name: name,
                    client_id: client_id,
                    slug: slug,
                    user_id: user.id,
                    is_default: is_default
                  }

                  attrs = inject_name_phase_b(attrs, user, vault_id)

                  case Repo.insert(Vault.changeset(%Vault{id: vault_id}, attrs)) do
                    {:ok, vault} ->
                      emit_vault_count(user.id, :created)
                      {:ok, decrypt_vault_if_needed(vault, user), :created}

                    {:error, cs} ->
                      {:error, cs}
                  end
              end
          end
        end)

      unwrap_register_transaction(result)
    end
  end

  # ── List ────────────────────────────────────────────────────────────────────

  @doc """
  Returns all non-deleted vaults for a user, ordered by inserted_at ascending.
  """
  def list_vaults(user) do
    user = fresh_user(user)

    {:ok, vaults} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from v in Vault,
            where: v.user_id == ^user.id and is_nil(v.deleted_at),
            order_by: [asc: fragment("created_at"), asc: v.id]
        )
      end)

    Enum.map(vaults, &decrypt_vault_if_needed(&1, user))
  end

  @doc """
  Loads vaults owned by `user` whose IDs appear in `vault_ids`.

  `vault_ids` is a list of strings (as they arrive from Qdrant payload JSON).
  Non-integer entries are silently filtered (they cannot match an integer PK).
  Returns a map keyed by stringified vault id: `%{"5" => %Vault{}}`.

  Tenant scoping is enforced via an explicit `user_id == ^user_id` clause.
  RLS is bypassed (`skip_tenant_check: true`) for performance — the explicit
  clause is the sole guarantee, so it MUST NOT be removed. Excludes
  soft-deleted vaults, matching `list_vaults/1` and `get_vault/2` conventions.
  """
  @spec list_for_ids(Engram.Accounts.User.t(), [String.t()]) :: %{String.t() => Vault.t()}
  def list_for_ids(%Engram.Accounts.User{id: user_id}, vault_ids) when is_list(vault_ids) do
    ids =
      vault_ids
      |> Enum.uniq()
      |> Enum.flat_map(fn s ->
        case Integer.parse(to_string(s)) do
          {n, ""} -> [n]
          _ -> []
        end
      end)

    if ids == [] do
      %{}
    else
      Vault
      |> where([v], v.user_id == ^user_id and v.id in ^ids and is_nil(v.deleted_at))
      |> Repo.all(skip_tenant_check: true)
      |> Map.new(fn v -> {to_string(v.id), v} end)
    end
  end

  # ── Get ─────────────────────────────────────────────────────────────────────

  @doc """
  Returns {:ok, vault} for a non-deleted vault owned by the user,
  or {:error, :not_found}.
  """
  def get_vault(user, vault_id) do
    user = fresh_user(user)

    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from v in Vault,
            where: v.user_id == ^user.id and v.id == ^vault_id and is_nil(v.deleted_at)
        )
      end)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, vault} -> {:ok, decrypt_vault_if_needed(vault, user)}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns {:ok, vault} for the user's default vault, or {:error, :no_default_vault}.
  """
  def get_default_vault(user) do
    user = fresh_user(user)

    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from v in Vault,
            where: v.user_id == ^user.id and v.is_default == true and is_nil(v.deleted_at)
        )
      end)

    case result do
      {:ok, nil} -> {:error, :no_default_vault}
      {:ok, vault} -> {:ok, decrypt_vault_if_needed(vault, user)}
      _ -> {:error, :no_default_vault}
    end
  end

  # ── Update ──────────────────────────────────────────────────────────────────

  @doc """
  Updates a vault's attributes.

  - If `is_default: true` is set, clears is_default on all other vaults first.
  - If `name` changes, regenerates the slug.

  Returns {:ok, vault} or {:error, :not_found} or {:error, changeset}.
  """
  def update_vault(user, vault_id, attrs) do
    # Ensure user has a DEK before Phase B injection
    with {:ok, user} <- Engram.Crypto.ensure_user_dek(user) do
      Repo.with_tenant(user.id, fn ->
        case fetch_active(user.id, vault_id) do
          nil ->
            {:error, :not_found}

          vault ->
            attrs =
              attrs
              |> atomize_keys()
              |> then(&maybe_regenerate_slug(user.id, vault, &1))
              |> inject_name_phase_b(user, vault.id)

            if Map.get(attrs, :is_default) == true do
              clear_defaults(user.id, vault_id)
            end

            vault
            |> Vault.changeset(attrs)
            |> Repo.update()
            |> case do
              {:ok, v} -> {:ok, decrypt_vault_if_needed(v, user)}
              other -> other
            end
        end
      end)
      |> unwrap_transaction()
    end
  end

  # ── Delete (soft) ───────────────────────────────────────────────────────────

  @doc """
  Soft-deletes a vault by setting deleted_at and clearing is_default.

  If the deleted vault was the default, promotes the next oldest non-deleted vault.

  Note: background cleanup (Qdrant vectors, S3 attachments) is handled by
  CleanupVault — a job is enqueued here scheduled 30 days out.

  Returns {:ok, vault} or {:error, :not_found}.
  """
  def delete_vault(user, vault_id) do
    Repo.with_tenant(user.id, fn ->
      case fetch_active(user.id, vault_id) do
        nil ->
          {:error, :not_found}

        vault ->
          was_default = vault.is_default

          result =
            vault
            |> Vault.changeset(%{
              deleted_at: DateTime.utc_now(:second),
              is_default: false
            })
            |> Repo.update()

          if was_default do
            promote_next_default(user.id)
          end

          case result do
            {:ok, deleted} ->
              _ = Engram.Workers.CleanupVault.enqueue(deleted.id, deleted.user_id)
              emit_vault_count(deleted.user_id, :deleted)
              result

            _ ->
              result
          end
      end
    end)
    |> unwrap_transaction()
  end

  # ── API key access check ────────────────────────────────────────────────

  @doc """
  Checks whether an API key is allowed to access a given vault.

  - If `api_key` is nil (JWT auth), access is always granted.
  - If the key has no rows in api_key_vaults, it has unrestricted access.
  - Otherwise the vault must appear in the key's allowed list.

  Returns `:ok` or `:forbidden`.
  """
  def check_api_key_access(nil, _vault), do: :ok

  def check_api_key_access(api_key, vault) do
    restricted_vault_ids =
      from(akv in "api_key_vaults",
        where: akv.api_key_id == ^api_key.id,
        select: akv.vault_id
      )
      |> Repo.all(skip_tenant_check: true)

    cond do
      restricted_vault_ids == [] -> :ok
      vault.id in restricted_vault_ids -> :ok
      true -> :forbidden
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # Phase B.1 — inject HMAC + ciphertext for the vault name.
  # Callers MUST call ensure_user_dek/1 before invoking this helper.
  # If get_dek still fails after ensure, that is a real bug — raises rather
  # than silently skipping to enforce the "Phase B is mandatory" contract.
  defp inject_name_phase_b(attrs, user, vault_id) do
    name = attrs[:name] || attrs["name"]

    if is_binary(name) do
      {:ok, dek} = Engram.Crypto.get_dek(user)
      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      aad = Engram.Crypto.aad_for_row(:vaults, :name, vault_id)
      {ct, n} = Engram.Crypto.Envelope.encrypt(name, dek, aad)

      Map.merge(attrs, %{
        name_ciphertext: ct,
        name_nonce: n,
        name_hmac: Engram.Crypto.hmac_field(filter_key, name),
        dek_version: Engram.Crypto.row_version_aad_bound()
      })
    else
      attrs
    end
  end

  defp count_vaults(user_id) do
    Repo.one!(
      from v in Vault,
        where: v.user_id == ^user_id and is_nil(v.deleted_at),
        select: count(v.id)
    )
  end

  defp fetch_active(user_id, vault_id) do
    Repo.one(
      from v in Vault,
        where: v.user_id == ^user_id and v.id == ^vault_id and is_nil(v.deleted_at)
    )
  end

  defp find_by_client_id(user_id, client_id) do
    Repo.one(
      from v in Vault,
        where: v.user_id == ^user_id and v.client_id == ^client_id and is_nil(v.deleted_at)
    )
  end

  defp clear_defaults(user_id, except_vault_id) do
    Repo.update_all(
      from(v in Vault,
        where: v.user_id == ^user_id and v.id != ^except_vault_id and v.is_default == true
      ),
      set: [is_default: false]
    )
  end

  defp promote_next_default(user_id) do
    next =
      Repo.one(
        from v in Vault,
          where: v.user_id == ^user_id and is_nil(v.deleted_at),
          order_by: [asc: fragment("created_at")],
          limit: 1
      )

    if next do
      Repo.update_all(
        from(v in Vault, where: v.id == ^next.id),
        set: [is_default: true]
      )
    end
  end

  defp maybe_regenerate_slug(user_id, vault, attrs) do
    new_name = Map.get(attrs, :name) || Map.get(attrs, "name")

    if new_name && new_name != vault.name do
      slug = unique_slug(user_id, slugify(new_name), vault.id)
      Map.put(attrs, :slug, slug)
    else
      attrs
    end
  end

  @doc false
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "vault"
      slug -> slug
    end
  end

  # Finds a slug that doesn't collide with any existing non-deleted vault for this user.
  # Optionally excludes `except_id` (for renames — the vault itself doesn't count).
  defp unique_slug(user_id, base_slug, except_id \\ nil) do
    query =
      from v in Vault,
        where: v.user_id == ^user_id and is_nil(v.deleted_at),
        select: v.slug

    query =
      if except_id do
        from v in query, where: v.id != ^except_id
      else
        query
      end

    existing = Repo.all(query)

    if base_slug in existing do
      Enum.find_value(2..1000, fn n ->
        candidate = "#{base_slug}-#{n}"
        if candidate not in existing, do: candidate
      end)
    else
      base_slug
    end
  end

  # with_tenant wraps the result in {:ok, value} — unwrap it cleanly.
  defp unwrap_transaction({:ok, {:ok, vault}}), do: {:ok, vault}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, _} = err), do: err

  defp unwrap_register_transaction({:ok, {:ok, vault, tag}}), do: {:ok, vault, tag}
  defp unwrap_register_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_register_transaction({:error, _} = err), do: err

  # Converts string-keyed maps to atom-keyed so atom merges don't produce mixed maps.
  defp atomize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Reload the user struct if its in-memory `encrypted_dek` is nil — the
  # caller may be holding a stale struct from before a write provisioned a
  # DEK. Same hazard the Attachments context handles via fresh_user/1.
  defp fresh_user(%Engram.Accounts.User{encrypted_dek: nil} = user), do: Repo.reload!(user)
  defp fresh_user(%Engram.Accounts.User{} = user), do: user

  # Decrypts vault.name from name_ciphertext when populated. On decrypt
  # failure logs and returns the row unchanged — operator visibility without
  # killing the request. Mirrors `decrypt_if_needed` in Notes context.
  defp decrypt_vault_if_needed(%Vault{} = vault, user) do
    case Engram.Crypto.maybe_decrypt_vault_fields(vault, user) do
      {:ok, decrypted} ->
        decrypted

      {:error, reason} ->
        require Logger

        Logger.error(
          "vault decrypt_failed user_id=#{user.id} vault_id=#{vault.id} reason=#{inspect(reason)}"
        )

        vault
    end
  end
end
