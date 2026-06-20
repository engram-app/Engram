defmodule EngramWeb.UsersController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Accounts

  operation(:me,
    operation_id: "account-me",
    summary: "Get the current user",
    description: "Returns the authenticated user's id, email, role, and display name.",
    tags: ["Account"],
    responses: [ok: {"Current user", "application/json", Schemas.UserResponse}]
  )

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      user: %{
        id: user.id,
        email: user.email,
        role: user.role,
        display_name: user.display_name
      }
    })
  end

  operation(:update,
    operation_id: "account-update",
    summary: "Update the current user's profile",
    description:
      "Updates the authenticated user's mutable profile fields (currently `display_name`) " <>
        "and returns the updated user.",
    tags: ["Account"],
    request_body:
      {"Profile fields", "application/json", Schemas.UpdateProfileRequest, required: true},
    responses: [
      ok: {"Updated user", "application/json", Schemas.UserResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ValidationError}
    ]
  )

  def update(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.take(params, ["display_name"])

    case Accounts.update_profile(user, attrs) do
      {:ok, updated} ->
        json(conn, %{
          user: %{
            id: updated.id,
            email: updated.email,
            role: updated.role,
            display_name: updated.display_name
          }
        })

      {:error, %Ecto.Changeset{} = cs} ->
        details =
          Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {k, v}, acc ->
              String.replace(acc, "%{#{k}}", to_string(v))
            end)
          end)

        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: details})
    end
  end

  operation(:delete,
    operation_id: "account-delete",
    summary: "Delete the current user's account",
    tags: ["Account"],
    description: "Irreversible. Requires the account password for confirmation.",
    request_body:
      {"Password confirmation", "application/json", Schemas.DeleteAccountRequest, required: true},
    responses: [
      ok: {"Account deleted", "application/json", Schemas.OkFlag},
      bad_request: {"password_required", "application/json", Schemas.MessageError},
      forbidden: {"invalid_password", "application/json", Schemas.MessageError},
      conflict:
        {"last_admin — cannot delete the only admin", "application/json", Schemas.MessageError},
      unprocessable_entity: {"delete_failed", "application/json", Schemas.MessageError}
    ]
  )

  def delete(conn, %{"password" => password}) when is_binary(password) do
    user = conn.assigns.current_user

    case Accounts.delete_self(user, password) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :invalid_password} ->
        conn |> put_status(403) |> json(%{error: "invalid_password"})

      {:error, :last_admin} ->
        conn |> put_status(409) |> json(%{error: "last_admin"})

      {:error, _other} ->
        conn |> put_status(422) |> json(%{error: "delete_failed"})
    end
  end

  def delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "password_required"})
  end
end
