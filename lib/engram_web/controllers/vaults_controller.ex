defmodule EngramWeb.VaultsController do
  use EngramWeb, :controller

  alias Engram.Auth.DeviceFlow
  alias Engram.Vaults

  @zero_counts %{notes: 0, attachments: 0}

  # ── index ──────────────────────────────────────────────────────────────────

  def index(conn, %{"deleted" => "true"}) do
    user = conn.assigns.current_user
    vaults = Vaults.list_deleted_vaults(user)
    counts = Vaults.content_counts_for(user, vaults)

    json(conn, %{
      vaults: Enum.map(vaults, &deleted_vault_json(&1, Map.get(counts, &1.id, @zero_counts)))
    })
  end

  def index(conn, params) do
    user = conn.assigns.current_user
    vaults = Vaults.list_vaults(user)
    counts = Vaults.content_counts_for(user, vaults)

    payload = %{
      vaults: Enum.map(vaults, &vault_json(&1, Map.get(counts, &1.id, @zero_counts)))
    }

    payload =
      case Map.get(params, "user_code") do
        code when is_binary(code) and code != "" ->
          Map.put(
            payload,
            :suggested_vault_name,
            DeviceFlow.suggested_vault_name(code, user.id)
          )

        _ ->
          payload
      end

    json(conn, payload)
  end

  # ── create ─────────────────────────────────────────────────────────────────

  def create(conn, params) do
    user = conn.assigns.current_user

    case Vaults.create_vault(user, params) do
      {:ok, vault} ->
        conn
        |> put_status(201)
        |> json(%{vault: vault_json(vault, Vaults.content_counts(user, vault.id))})

      {:error, {:vault_limit_reached, limit, current}} ->
        # Free-tier launch §4.5 — standardized 402 shape via LimitResponse.
        EngramWeb.LimitResponse.halt(
          conn,
          "vaults_cap_exceeded",
          :vaults_cap,
          limit,
          current
        )

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
          {:ok, vault} ->
            # Fires once per SPA navigation to /v/:id. The list endpoint
            # /vaults (index/2) is the picker fetch — emitting there would
            # conflate browsing with opening, so the event stays on show/2.
            _ =
              Engram.Observability.PostHog.capture(
                Engram.Observability.PostHog.distinct_id_for(user),
                "vault_opened",
                %{vault_id: vault.id}
              )

            json(conn, %{vault: vault_json(vault, Vaults.content_counts(user, vault.id))})

          {:error, :not_found} ->
            not_found(conn)
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
            json(conn, %{vault: vault_json(vault, Vaults.content_counts(user, vault.id))})

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

  # ── restore ──────────────────────────────────────────────────────────────────

  def restore(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case parse_id(id) do
      {:ok, vault_id} ->
        case Vaults.restore_vault(user, vault_id) do
          {:ok, vault} ->
            json(conn, %{vault: vault_json(vault, Vaults.content_counts(user, vault.id))})

          {:error, {:limit_reached, limit, current}} ->
            # Free-tier launch §4.5 — standardized 402 shape via LimitResponse.
            EngramWeb.LimitResponse.halt(
              conn,
              "vaults_cap_exceeded",
              :vaults_cap,
              limit,
              current
            )

          {:error, :not_found} ->
            not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  # ── purge (immediate hard delete) ──────────────────────────────────────────────

  def purge(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case parse_id(id) do
      {:ok, vault_id} ->
        case Vaults.purge_vault(user, vault_id) do
          {:ok, _vault} -> json(conn, %{purged: true, id: vault_id})
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
          |> json(
            vault_json(vault, Vaults.content_counts(user, vault.id))
            |> Map.put(:status, "created")
          )

        {:ok, vault, :existing} ->
          json(
            conn,
            vault_json(vault, Vaults.content_counts(user, vault.id))
            |> Map.put(:status, "existing")
          )

        {:error, {:vault_limit_reached, limit, current}} ->
          # Free-tier launch §4.5 — standardized 402 shape via LimitResponse.
          EngramWeb.LimitResponse.halt(
            conn,
            "vaults_cap_exceeded",
            :vaults_cap,
            limit,
            current
          )
      end
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp vault_json(vault, counts) do
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
      encrypted: true,
      note_count: counts.notes,
      attachment_count: counts.attachments
    }
  end

  defp deleted_vault_json(vault, counts) do
    vault
    |> vault_json(counts)
    |> Map.merge(%{
      deleted_at: vault.deleted_at,
      purge_at: purge_at(vault.deleted_at)
    })
  end

  defp purge_at(nil), do: nil
  defp purge_at(deleted_at), do: DateTime.add(deleted_at, 30 * 86_400, :second)

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: "not found"})
  end

  defp parse_id(id) when is_binary(id), do: Ecto.UUID.cast(id)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
