defmodule EngramWeb.SignupRejectionController do
  @moduledoc """
  Public lookup for why a just-completed sign-up was rejected server-side.

  Unauthenticated by necessity: the multi-account block deletes the Clerk user,
  so the caller no longer holds a valid session. The web app passes the orphaned
  Clerk user id to learn the reason and show an accurate message instead of a
  silent bounce to sign-in. Rate-limited; ids are opaque and short-lived.
  """
  use EngramWeb, :controller

  alias Engram.Auth.SignupRejections

  def show(conn, %{"clerk_id" => clerk_id}) when is_binary(clerk_id) and clerk_id != "" do
    case SignupRejections.fetch(clerk_id) do
      {:ok, reason} ->
        json(conn, %{reason: Atom.to_string(reason)})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{reason: nil})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "clerk_id is required"})
  end
end
