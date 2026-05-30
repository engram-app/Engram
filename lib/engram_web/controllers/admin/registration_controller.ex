defmodule EngramWeb.Admin.RegistrationController do
  use EngramWeb, :controller
  alias Engram.Instance

  def show(conn, _params) do
    json(conn, %{registration_mode: Instance.registration_mode()})
  end

  def update(conn, %{"mode" => mode}) do
    case Instance.set_registration_mode(mode) do
      {:ok, _} -> json(conn, %{registration_mode: mode})
      {:error, :invalid_mode} -> conn |> put_status(422) |> json(%{error: "invalid_mode"})
    end
  end
end
