defmodule EngramWeb.FeedbackController do
  use EngramWeb, :controller

  alias Engram.Feedback

  def create(conn, %{"kind" => kind} = params) when is_binary(kind) do
    case Feedback.submit(conn.assigns.current_user, kind, params) do
      :ok -> json(conn, %{status: "ok"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})
    end
  end

  def create(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid_kind"})
end
