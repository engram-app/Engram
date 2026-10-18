defmodule EngramWeb.VaultsController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Accounts.ApiKey
  alias Engram.Auth.DeviceFlow
  alias Engram.Vaults
  alias Engram.Vaults.WelcomeNote

  action_fallback EngramWeb.FallbackController

  @zero_counts %{notes: 0, attachments: 0}

  # ── index ──────────────────────────────────────────────────────────────────

  operation(:index,
    operation_id: "vaults-index",
    summary: "List vaults",
    description:
      "Lists the user's active vaults with their note and attachment counts. Pass `deleted=true` " <>
        "to list soft-deleted vaults instead, or `user_code` to also report `user_code_valid` " <>
        "and a `suggested_vault_name` for an in-progress device link.",
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

    # A deleted vault is listed only where the credential holds it
    # explicitly: the new-vaults policy covers vaults created after the
    # credential, never one that was deleted (#174, #332).
    # Nor one deleted before the credential (OAuth grant or leveled key) itself
    # existed: it is not restorable by it either (`with_restorable_vault/3`).
    scope = Engram.Permissions.vault_scope(conn)
    granted = credential_created_at(conn)

    vaults =
      Enum.filter(
        Vaults.list_deleted_vaults(user),
        &(Engram.Permissions.explicit_level(scope, &1) != :none and
            not deleted_before?(&1.deleted_at, granted))
      )

    counts = Vaults.content_counts_for(user, vaults)

    json(conn, %{
      vaults: Enum.map(vaults, &deleted_vault_json(&1, Map.get(counts, &1.id, @zero_counts)))
    })
  end

  def index(conn, params) do
    user = conn.assigns.current_user
    payload = index_payload(user, Engram.Permissions.vault_scope(conn))

    payload =
      case Map.get(params, "user_code") do
        code when is_binary(code) and code != "" ->
          # `user_code_valid` is the ONLY reliable validity signal here — a
          # real code may legitimately have no `suggested_vault_name`, so a
          # nil name says nothing about the code. /link rejects on this field.
          {valid, suggested, device_name} =
            case DeviceFlow.view_pending_hints(code, user.id) do
              {:ok, hints} -> {true, hints.vault_name, hints.device_name}
              :error -> {false, nil, nil}
            end

          payload
          |> Map.put(:suggested_vault_name, suggested)
          |> Map.put(:user_code_valid, valid)
          |> Map.put(:suggested_device_name, device_name)

        _ ->
          payload
      end

    json(conn, payload)
  end

  @doc """
  Builds the base `GET /api/vaults` JSON map (`%{vaults: [...]}`) for a user.
  Public so the consolidated `GET /api/bootstrap` endpoint serves the identical
  list shape without the device-link `user_code` extension.

  `scope` narrows the list to what the request's credential may reach. Without
  it a token scoped to one vault could still enumerate the names of every other
  vault the user owns — the same leak the MCP list path closed in #729.
  """
  def index_payload(user, scope \\ :all) do
    vaults = Engram.Permissions.filter(scope, Vaults.list_vaults(user))

    counts = Vaults.content_counts_for(user, vaults)

    %{
      vaults: Enum.map(vaults, &vault_json(&1, Map.get(counts, &1.id, @zero_counts))),
      # Capability flag (#174, #332): this server stores per-vault access
      # levels and `mcp:read`. The SPA shows the level pickers and "Read only"
      # only when it is present, so a new SPA never sends them to a server
      # that would silently ignore them.
      access_levels: true
    }
  end

  # `POST /vaults` used to live here. It created a vault per call with no
  # idempotency key, so a client that retried a slow or failed request got a
  # SECOND vault — which is how one Obsidian first-sync produced two vaults and
  # orphaned 292 uploads into the abandoned one. `POST /vaults/register` (the
  # `:register` action below) is now the only create endpoint.

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

    with_scoped_vault(conn, id, fn vault_id ->
      case Vaults.get_vault(user, vault_id) do
        {:ok, vault} ->
          # Fires once per SPA navigation to /v/:id. The list endpoint
          # /vaults (index/2) is the picker fetch — emitting there would
          # conflate browsing with opening, so the event stays on show/2.
          _ =
            Engram.Analytics.track(user, "vault_opened", %{vault_id: vault.id})

          json(conn, %{vault: vault_json(vault, Vaults.content_counts(user, vault.id))})

        {:error, :not_found} ->
          not_found(conn)
      end
    end)
  end

  # ── update ─────────────────────────────────────────────────────────────────

  operation(:update,
    operation_id: "vaults-update",
    summary: "Update a vault",
    description:
      "Updates a vault's `name` or `is_default` flag and returns the updated " <>
        "vault. Returns 404 when no such vault exists and 422 on validation errors.",
    tags: ["Vaults"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Vault UUID"]],
    request_body:
      {"Fields to change", "application/json", Schemas.UpdateVaultRequest, required: true},
    responses: [
      ok: {"Updated", "application/json", Schemas.VaultResponse},
      forbidden:
        {"Vault only readable by the credential: this needs write access to the vault",
         "application/json", Schemas.MessageError},
      not_found:
        {"No such vault, or one the credential cannot reach (the two look the same)",
         "application/json", Schemas.MessageError},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = Map.take(params, ["name", "is_default"])

    with_writable_vault(conn, id, fn vault_id ->
      case Vaults.update_vault(user, vault_id, attrs) do
        {:ok, vault} ->
          json(conn, %{vault: vault_json(vault, Vaults.content_counts(user, vault.id))})

        {:error, :not_found} ->
          not_found(conn)

        {:error, %Ecto.Changeset{}} = error ->
          error
      end
    end)
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
      forbidden:
        {"Vault only readable by the credential: this needs write access to the vault",
         "application/json", Schemas.MessageError},
      not_found:
        {"No such vault, or one the credential cannot reach (the two look the same)",
         "application/json", Schemas.MessageError}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with_writable_vault(conn, id, fn vault_id ->
      case Vaults.delete_vault(user, vault_id) do
        {:ok, vault} -> json(conn, %{deleted: true, id: vault.id})
        {:error, :not_found} -> not_found(conn)
      end
    end)
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
      forbidden:
        {"The credential may not restore this vault: this needs write access to it",
         "application/json", Schemas.MessageError},
      not_found:
        {"No such vault, or one the credential cannot reach (the two look the same)",
         "application/json", Schemas.MessageError}
    ]
  )

  def restore(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with_restorable_vault(conn, id, fn vault_id ->
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
    end)
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

    with_scoped_vault(conn, id, fn vault_id ->
      case Vaults.purge_vault(user, vault_id) do
        {:ok, _vault} -> json(conn, %{purged: true, id: vault_id})
        {:error, :not_found} -> not_found(conn)
      end
    end)
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
      forbidden:
        {"Vault outside the credential's scope, or creation by a credential whose new-vaults " <>
           "policy is not write (a vault-restricted, read-level or `mcp:read` credential)",
         "application/json", Schemas.MessageError},
      payment_required: {"Vault cap reached", "application/json", Schemas.LimitError},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def register(conn, params) do
    user = conn.assigns.current_user
    name = params["name"]
    client_id = params["client_id"]

    # Type check, not just presence: JSON gives us whatever the client sent,
    # and a non-string `name` reached `slugify/1` and raised into a 500.
    if not is_binary(name) or not is_binary(client_id) do
      conn
      |> put_status(400)
      |> json(%{error: "name and client_id are required"})
    else
      # #1869: a vault-restricted credential may only resolve a vault inside
      # its scope. Creating one needs a WRITE new-vaults policy (#174, #332):
      # a vault created now is reached through that policy, so with none or
      # read the credential could not use what it made. Both refusals are the
      # same 403, so register is not an existence oracle.
      scope = Engram.Permissions.vault_scope(conn)
      create? = Engram.Permissions.new_vault_level(scope) == :write

      case Vaults.register_vault(user, name, client_id, %{}, create?: create?) do
        {:ok, vault, :created} ->
          # A brand-new user gets their DEK inside the seed below, but `user`
          # predates it. Without the DEK the counts cannot recognise the welcome
          # note, and a welcome-only vault would come back `populated: true`.
          user =
            case Engram.Crypto.ensure_user_dek(user) do
              {:ok, user} -> user
              _ -> user
            end

          WelcomeNote.seed(user, vault)

          conn
          |> put_status(201)
          |> json(
            vault_json(vault, Vaults.content_counts(user, vault.id))
            |> Map.put(:status, "created")
          )

        {:ok, vault, :existing} ->
          if Engram.Permissions.decide(scope, vault, :read) == :ok do
            json(
              conn,
              vault_json(vault, Vaults.content_counts(user, vault.id))
              |> Map.put(:status, "existing")
            )
          else
            forbidden(conn)
          end

        {:error, :create_forbidden} ->
          forbidden(conn)

        {:error, {:vault_limit_reached, limit, current}} ->
          # Free-tier launch §4.5 — standardized 402 shape via LimitResponse.
          EngramWeb.LimitResponse.halt(
            conn,
            "vaults_cap_exceeded",
            :vaults_cap,
            limit,
            current
          )

        {:error, :invalid_client_id} ->
          conn
          |> put_status(400)
          |> json(%{error: "client_id must be a non-blank string"})

        # Reachable since blank names became rejectable (#1213): a blank
        # `name` passes the type guard above but fails the changeset.
        {:error, %Ecto.Changeset{}} = error ->
          error

        # Residual error space collapses to the fallback's 500 rather than a
        # CaseClauseError. Everything this action wants to render differently
        # is matched above, which is the condition FallbackController documents
        # for delegating here.
        {:error, _reason} = error ->
          error
      end
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp vault_json(vault, counts) do
    %{
      id: vault.id,
      name: vault.name,
      slug: vault.slug,
      is_default: vault.is_default,
      created_at: vault.created_at,
      # Phase B.4: encryption is mandatory and one-way. Surfaced as a
      # constant `true` for clients still consuming this field; the toggle
      # is gone.
      encrypted: true,
      note_count: counts.notes,
      attachment_count: counts.attachments,
      # Has a note other than the seeded welcome note: whether the one-shot
      # `vault_populated` event is still to come. See `Vaults.content_counts_for/2`.
      populated: counts.populated
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

  # Every per-vault action routes through here: parse the id, then check it
  # against what THIS request's credential may reach. A vault-scoped OAuth
  # grant (or a restricted API key) must not delete, purge, restore, rename or
  # read a vault outside its grant — `index`/`show` leaked names, and
  # delete/purge were outright destructive.
  #
  # Checked against the id alone, with no fetch: that works for soft-deleted
  # vaults (restore/purge operate on them). A vault the credential cannot
  # reach is a 404 identical to a missing one, so the answer reveals nothing
  # about which UUIDs exist.
  defp with_scoped_vault(conn, id, fun), do: with_vault_level(conn, id, :read, fun)

  # Rename and delete change the vault, so they need WRITE on
  # it (#174, #332): a read-level vault, listed or reached through the
  # new-vaults policy, is refused 403. That 403 only goes to a vault the
  # credential can already see; see `with_vault_level/4`.
  defp with_writable_vault(conn, id, fun), do: with_vault_level(conn, id, :write, fun)

  # Restore needs write LISTED on the vault, not write through the new-vaults
  # policy: that policy is for vaults created after the credential, and a
  # restored vault is not one. (A vault deleted before the credential existed
  # is recorded as none at creation, `Permissions.resolve_access/2`.)
  # An explicitly listed write, and for an OAuth grant or leveled API key a
  # vault deleted AFTER the credential was created: a vault already in the
  # trash at consent or key creation was never offered to it. This is what
  # keeps an unrestricted grant (NULL: no levels to record the trash in) from
  # restoring one; a leveled credential records such vaults as `none`
  # anyway. A key without levels keeps its pre-levels reach
  # (`credential_created_at/1`).
  defp with_restorable_vault(conn, id, fun) do
    with_vault_level(
      conn,
      id,
      :write,
      fun,
      &(Engram.Permissions.explicit_level(&1, &2) == :write and
          not deleted_before_credential?(conn, &2.id))
    )
  end

  # A grant that is revoked, gone or not this user's (`:revoked`) restores
  # nothing; the auth plugs refuse such a request before it gets here.
  defp deleted_before_credential?(conn, vault_id) do
    case credential_created_at(conn) do
      nil -> false
      :revoked -> true
      granted -> deleted_before?(Vaults.deleted_at(conn.assigns.current_user, vault_id), granted)
    end
  end

  # A leveled API key's `created_at`, an OAuth grant's `granted_at`, or nil:
  # no bound. nil for a session, a grant token minted before `gid`, and a key
  # without levels (NULL `default_access`), which means every vault, trash
  # included, exactly as before levels existed.
  defp credential_created_at(%{assigns: %{current_api_key: %ApiKey{default_access: nil}}}),
    do: nil

  defp credential_created_at(%{assigns: %{current_api_key: %ApiKey{created_at: created}}}),
    do: created

  defp credential_created_at(conn) do
    Engram.OAuth.granted_at(%{
      "gid" => conn.assigns[:oauth_grant_id],
      "user_id" => conn.assigns.current_user.id
    })
  end

  # `deleted_at` has second precision: a vault deleted in the very second the
  # grant was created counts as after it.
  defp deleted_before?(%DateTime{} = deleted, %DateTime{} = granted),
    do: DateTime.compare(deleted, DateTime.truncate(granted, :second)) == :lt

  defp deleted_before?(_deleted, _granted), do: false

  # Out of reach and nonexistent are one 404, or the status is an existence
  # oracle. A visible vault the action still refuses (write on a read vault)
  # is 403, but a read or write new-vaults policy also "sees" every random
  # UUID, so the 403 is only given once the vault is known to exist.
  # `need` is judged by `Permissions.decide/3`; `also?` is an action's extra
  # rule on top of it (restore's listed-write and trash bound).
  defp with_vault_level(conn, id, need, fun, also? \\ fn _scope, _vault -> true end) do
    scope = Engram.Permissions.vault_scope(conn)

    with {:ok, vault_id} <- parse_id(id),
         :ok <- Engram.Permissions.decide(scope, %{id: vault_id}, need),
         true <- also?.(scope, %{id: vault_id}) || :read_only do
      fun.(vault_id)
    else
      :read_only ->
        if vault_exists?(conn.assigns.current_user, id),
          do: forbidden(conn),
          else: not_found(conn)

      _hidden_or_malformed ->
        not_found(conn)
    end
  end

  # Active or in the trash: restore refuses on a trashed vault.
  defp vault_exists?(user, vault_id),
    do:
      match?({:ok, _}, Vaults.get_vault(user, vault_id)) or
        Vaults.deleted_at(user, vault_id) != nil

  defp forbidden(conn) do
    conn |> put_status(:forbidden) |> json(%{error: "Not authorized for this vault"})
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: "not found"})
  end

  defp parse_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
end
