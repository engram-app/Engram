defmodule EngramWeb.FallbackController do
  @moduledoc """
  Shared `action_fallback` renderer for the recurring error-tuple → JSON
  conventions used across the API controllers.

  ## Contract

  Every clause here reproduces — byte-for-byte — a response shape that was
  already hand-rolled in three or more controllers before this module
  existed. **Never invent a new shape in this module.** A new clause is only
  admissible when it matches an existing, repeated in-controller convention
  exactly (status + JSON body). Bespoke or one-off responses (custom bodies,
  `LimitResponse` halts, `%{error: "not found"}` with a space, `item_path`
  variants, logged catch-alls) stay in their controllers.

  ## Clauses

  | Tuple                          | Status | Body                                     |
  |--------------------------------|--------|------------------------------------------|
  | `{:error, %Ecto.Changeset{}}`  | 422    | `%{errors: EngramWeb.format_errors(cs)}` |
  | `{:error, :not_found}`         | 404    | `%{error: "not_found"}`                  |
  | `{:error, {:not_found, id}}`   | 404    | `%{error: "not_found", item_id: id}`     |
  | `{:error, :conflict}`          | 409    | `%{error: "conflict"}`                   |
  | `{:error, {:conflict, id}}`    | 409    | `%{error: "conflict", item_id: id}`      |
  | `{:error, :last_admin}`        | 409    | `%{error: "last_admin"}`                 |
  | `{:error, transient DEK}`      | 503    | `%{error: "dek_unavailable"}`            |
  | `{:error, _}` (terminal)       | 500    | `%{error: "internal"}`                   |

  The terminal `{:error, _}` clause mirrors the `%{error: "internal"}`
  catch-all the notes/folders/attachments batch actions already used. An
  action must only delegate to this fallback when its residual error space is
  meant to collapse to that 500 — otherwise keep the branch inline.
  """
  use EngramWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn |> put_status(422) |> json(%{errors: EngramWeb.format_errors(changeset)})
  end

  def call(conn, {:error, :not_found}) do
    conn |> put_status(404) |> json(%{error: "not_found"})
  end

  def call(conn, {:error, {:not_found, id}}) do
    conn |> put_status(404) |> json(%{error: "not_found", item_id: id})
  end

  def call(conn, {:error, :conflict}) do
    conn |> put_status(409) |> json(%{error: "conflict"})
  end

  def call(conn, {:error, {:conflict, id}}) do
    conn |> put_status(409) |> json(%{error: "conflict", item_id: id})
  end

  # A rename/move target that sanitizes to nothing (PathSanitizer.sanitize_target/1).
  def call(conn, {:error, :invalid_path}) do
    conn |> put_status(422) |> json(%{error: "invalid_path"})
  end

  def call(conn, {:error, :last_admin}) do
    conn |> put_status(409) |> json(%{error: "last_admin"})
  end

  # A stalled or contended DEK load (`Engram.Crypto.transient_dek_error?/1`)
  # clears on retry, so it must not read as the terminal 500. Its Retry-After
  # comes from `EngramWeb.Plugs.RetryAfter`, as every 503's does. Same body as
  # `Engram.Crypto.DekUnavailableError` renders for the raising paths.
  def call(conn, {:error, reason}) do
    if Engram.Crypto.transient_dek_error?(reason) do
      conn |> put_status(503) |> json(%{error: "dek_unavailable"})
    else
      conn |> put_status(500) |> json(%{error: "internal"})
    end
  end
end
