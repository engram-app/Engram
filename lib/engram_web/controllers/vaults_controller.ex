defmodule EngramWeb.VaultsController do
  use EngramWeb, :controller

  alias Engram.Billing
  alias Engram.Vaults

  # ── index ──────────────────────────────────────────────────────────────────

  def index(conn, _params) do
    user = conn.assigns.current_user
    vaults = Vaults.list_vaults(user)
    json(conn, %{vaults: Enum.map(vaults, &vault_json(&1, user))})
  end

  # ── create ─────────────────────────────────────────────────────────────────

  def create(conn, params) do
    user = conn.assigns.current_user

    case Vaults.create_vault(user, params) do
      {:ok, vault} ->
        conn
        |> put_status(201)
        |> json(%{vault: vault_json(vault, user)})

      {:error, :vault_limit_reached} ->
        limit = Billing.effective_limit(user, "max_vaults")

        conn
        |> put_status(402)
        |> json(%{error: "vault_limit_reached", limit: limit})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ── show ───────────────────────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case parse_id(id) do
      {:ok, vault_id} ->
        case Vaults.get_vault(user, vault_id) do
          {:ok, vault} -> json(conn, %{vault: vault_json(vault, user)})
          {:error, :not_found} -> not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  # ── update ─────────────────────────────────────────────────────────────────

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = Map.take(params, ["name", "description", "is_default"])

    case parse_id(id) do
      {:ok, vault_id} ->
        case Vaults.update_vault(user, vault_id, attrs) do
          {:ok, vault} ->
            json(conn, %{vault: vault_json(vault, user)})

          {:error, :not_found} ->
            not_found(conn)

          {:error, changeset} ->
            conn
            |> put_status(422)
            |> json(%{errors: format_errors(changeset)})
        end

      :error ->
        not_found(conn)
    end
  end

  # ── delete ─────────────────────────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case parse_id(id) do
      {:ok, vault_id} ->
        case Vaults.delete_vault(user, vault_id) do
          {:ok, vault} -> json(conn, %{deleted: true, id: vault.id})
          {:error, :not_found} -> not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  # ── encrypt / decrypt toggles ──────────────────────────────────────────────

  def encrypt(conn, %{"id" => id}) do
    toggle_action(conn, id, &Engram.Crypto.encrypt_vault/2)
  end

  # Phase B.3: vault decryption actions retired. At-rest encryption is
  # mandatory; per-note reads decrypt on demand. The toggle UI + the
  # `vault.encrypted` / `encryption_status` schema fields are removed in
  # B.4. Until then, the decrypt routes simply do not exist.

  def encryption_progress(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, vault_id} <- parse_vault_id(id),
         {:ok, vault} <- Vaults.get_vault(user, vault_id) do
      %{processed: p, total: t} = Vaults.encryption_progress(vault)

      started_at =
        case vault.encryption_status do
          "encrypting" -> vault.last_toggle_at
          "decrypting" -> vault.decrypt_requested_at
          _ -> nil
        end

      json(conn, %{
        processed: p,
        total: t,
        status: vault.encryption_status,
        started_at: started_at
      })
    else
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> not_found(conn)
    end
  end

  # ── register ───────────────────────────────────────────────────────────────

  def register(conn, params) do
    user = conn.assigns.current_user
    name = params["name"]
    client_id = params["client_id"]

    if is_nil(name) or is_nil(client_id) do
      conn
      |> put_status(400)
      |> json(%{error: "name and client_id are required"})
    else
      case Vaults.register_vault(user, name, client_id) do
        {:ok, vault, :created} ->
          conn
          |> put_status(201)
          |> json(vault_json(vault, user) |> Map.put(:status, "created"))

        {:ok, vault, :existing} ->
          json(conn, vault_json(vault, user) |> Map.put(:status, "existing"))

        {:error, :vault_limit_reached} ->
          limit = Billing.effective_limit(user, "max_vaults")

          conn
          |> put_status(402)
          |> json(%{error: "vault_limit_reached", limit: limit})
      end
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp vault_json(vault, user) do
    %{
      id: vault.id,
      name: vault.name,
      description: vault.description,
      slug: vault.slug,
      is_default: vault.is_default,
      created_at: vault.created_at,
      encrypted: vault.encrypted,
      encryption_status: vault.encryption_status,
      encrypted_at: vault.encrypted_at,
      decrypt_requested_at: vault.decrypt_requested_at,
      last_toggle_at: vault.last_toggle_at,
      cooldown_days: cooldown_days_for(user)
    }
  end

  defp cooldown_days_for(%Engram.Accounts.User{encryption_toggle_cooldown_days: days}), do: days
  defp cooldown_days_for(_), do: nil

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: "not found"})
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  # with/1-friendly variant — returns {:error, :invalid_id} instead of bare :error
  defp parse_vault_id(id) do
    case parse_id(id) do
      {:ok, n} -> {:ok, n}
      :error -> {:error, :invalid_id}
    end
  end

  defp toggle_action(conn, id, fun) do
    user = conn.assigns.current_user

    with {:ok, vault_id} <- parse_vault_id(id),
         {:ok, vault} <- Vaults.get_vault(user, vault_id),
         {:ok, updated} <- fun.(vault, user) do
      conn |> put_status(202) |> json(%{vault: vault_json(updated, user)})
    else
      {:error, :not_found} ->
        not_found(conn)

      {:error, :invalid_id} ->
        not_found(conn)

      {:error, :cooldown} ->
        retry_after = compute_retry_after(id, user)

        conn
        |> put_status(429)
        |> json(%{error: "cooldown_active", retry_after: retry_after})

      {:error, :bad_status} ->
        conn
        |> put_status(409)
        |> json(%{error: "invalid_status_transition"})

      _ ->
        send_resp(conn, 500, "")
    end
  end

  defp compute_retry_after(id, %Engram.Accounts.User{} = user) do
    with days when is_integer(days) and days > 0 <- user.encryption_toggle_cooldown_days,
         {:ok, vault_id} <- parse_vault_id(id),
         {:ok, vault} <- Vaults.get_vault(user, vault_id),
         %DateTime{} = toggled <- vault.last_toggle_at do
      toggled |> DateTime.add(days, :day) |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
