defmodule EngramWeb.VaultsController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Auth.DeviceFlow
  alias Engram.Vaults

  @zero_counts %{notes: 0, attachments: 0}

  # ── index ──────────────────────────────────────────────────────────────────

  operation(:index,
    operation_id: "vaults-index",
    summary: "List vaults",
    description:
      "Lists the user's active vaults with their note and attachment counts. Pass `deleted=true` " <>
        "to list soft-deleted vaults instead, or `user_code` to also echo a `suggested_vault_name` " <>
        "for an in-progress device link.",
    tags: ["Vaults"],
    parameters: [
      deleted: [
        in: :query,
        type: :string,
        required: false,
        description: "Pass \"true\" to list soft-deleted vaults instead of active ones."
      ],
      user_code: [
        in: :query,
        type: :string,
        required: false,
        description: "Device-link user code; echoes a `suggested_vault_name`."
      ]
    ],
    responses: [ok: {"Vaults", "application/json", Schemas.VaultsResponse}]
  )

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
    payload = index_payload(user)

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

  @doc """
  Builds the base `GET /api/vaults` JSON map (`%{vaults: [...]}`) for a user.
  Public so the consolidated `GET /api/bootstrap` endpoint serves the identical
  list shape without the device-link `user_code` extension.
  """
  def index_payload(user) do
    vaults = Vaults.list_vaults(user)
    counts = Vaults.content_counts_for(user, vaults)

    %{vaults: Enum.map(vaults, &vault_json(&1, Map.get(counts, &1.id, @zero_counts)))}
  end

  # ── create ─────────────────────────────────────────────────────────────────

  operation(:create,
    operation_id: "vaults-create",
    summary: "Create a vault",
    description:
      "Creates a new vault for the user and returns it with zeroed content counts. Returns 402 " <>
        "when the plan's vault cap is reached and 422 on validation errors.",
    tags: ["Vaults"],
    request_body:
      {"Vault attributes", "application/json", Schemas.CreateVaultRequest, required: true},
    responses: [
      created: {"Created", "application/json", Schemas.VaultResponse},
      payment_required: {"Vault cap reached", "application/json", Schemas.LimitError},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

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

  operation(:show,
    operation_id: "vaults-show",
    summary: "Get a vault by id",
    description:
      "Returns the vault with the given UUID along with its current note and attachment counts, " <>
        "or 404 if it does not exist or belong to the user. Opening a vault also emits a " <>
        "`vault_opened` analytics event.",
    tags: ["Vaults"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Vault UUID"]],
    responses: [
      ok: {"Vault", "application/json", Schemas.VaultResponse},
      not_found: {"No such vault", "application/json", Schemas.MessageError}
    ]
  )

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

  operation(:update,
    operation_id: "vaults-update",
    summary: "Update a vault",
    description:
      "Updates a vault's `name`, `description`, or `is_default` flag and returns the updated " <>
        "vault. Returns 404 when no such vault exists and 422 on validation errors.",
    tags: ["Vaults"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Vault UUID"]],
    request_body:
      {"Fields to change", "application/json", Schemas.UpdateVaultRequest, required: true},
    responses: [
      ok: {"Updated", "application/json", Schemas.VaultResponse},
      not_found: {"No such vault", "application/json", Schemas.MessageError},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

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

  operation(:delete,
    operation_id: "vaults-delete",
    summary: "Soft-delete a vault",
    description:
      "Soft-deletes the vault, keeping it restorable for 30 days before it is permanently purged. " <>
        "Returns 404 when no such vault exists.",
    tags: ["Vaults"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Vault UUID"]],
    responses: [
      ok: {"Soft-deleted (restorable for 30 days)", "application/json", Schemas.VaultDeleted},
      not_found: {"No such vault", "application/json", Schemas.MessageError}
    ]
  )

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

  operation(:restore,
    operation_id: "vaults-restore",
    summary: "Restore a soft-deleted vault",
    description:
      "Restores a soft-deleted vault back to active within its 30-day window. Returns 402 when " <>
        "restoring would exceed the plan's vault cap and 404 when no such vault exists.",
    tags: ["Vaults"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Vault UUID"]],
    responses: [
      ok: {"Restored", "application/json", Schemas.VaultResponse},
      payment_required: {"Vault cap reached", "application/json", Schemas.LimitError},
      not_found: {"No such vault", "application/json", Schemas.MessageError}
    ]
  )

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

  operation(:purge,
    operation_id: "vaults-purge",
    summary: "Permanently purge a vault",
    tags: ["Vaults"],
    description: "Immediate, irreversible hard delete — skips the 30-day soft-delete window.",
    parameters: [id: [in: :path, type: :string, required: true, description: "Vault UUID"]],
    responses: [
      ok: {"Purged", "application/json", Schemas.VaultPurged},
      not_found: {"No such vault", "application/json", Schemas.MessageError}
    ]
  )

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

  operation(:register,
    operation_id: "vaults-register",
    summary: "Register or fetch a vault by client_id (idempotent)",
    tags: ["Vaults"],
    description:
      "Used by the plugin on first sync. Returns 201 with `status: created` for a new " <>
        "vault, or 200 with `status: existing` when the client_id already maps to one.",
    request_body:
      {"Name + client_id", "application/json", Schemas.RegisterVaultRequest, required: true},
    responses: [
      ok: {"Existing vault", "application/json", Schemas.RegisterVaultResponse},
      created: {"Newly created vault", "application/json", Schemas.RegisterVaultResponse},
      bad_request: {"name and client_id are required", "application/json", Schemas.MessageError},
      payment_required: {"Vault cap reached", "application/json", Schemas.LimitError}
    ]
  )

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
