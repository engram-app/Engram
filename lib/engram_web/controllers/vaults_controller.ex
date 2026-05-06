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

  # Phase B.4: encrypt/decrypt toggle actions are retired. Every vault is
  # encrypted at rest by definition; per-note reads decrypt on demand.

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

  defp vault_json(vault, _user) do
    %{
      id: vault.id,
      name: vault.name,
      description: vault.description,
      slug: vault.slug,
      is_default: vault.is_default,
      created_at: vault.created_at,
      # Phase B.4: encryption is mandatory and one-way. Surfaced as a
      # constant `true` for clients still consuming this field; the toggle
      # is gone.
      encrypted: true
    }
  end

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

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
