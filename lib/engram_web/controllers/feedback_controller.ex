defmodule EngramWeb.FeedbackController do
  use EngramWeb, :controller

  alias Engram.Feedback

  # This scope skips the API RPS budget, so feedback carries its own hourly
  # cap (`Feedback.allow?/1`), shared with the MCP send_feedback tool.
  # The plugin's device token is admitted for the feedback box only, not the
  # survey, cancel or delete answers (see :require_session_allow_plugin).
  # `device_token` is `false` (not nil) on a web session JWT, so match `true`.
  def create(%{assigns: %{device_token: true}} = conn, %{"kind" => kind})
      when kind != "general" do
    conn |> put_status(403) |> json(%{error: "device_token_not_allowed"})
  end

  def create(conn, %{"kind" => kind} = params) when is_binary(kind) do
    user = conn.assigns.current_user
    # Server-stamped, so a client cannot send a misleading one.
    params = Map.put(params, "user_agent", conn |> get_req_header("user-agent") |> List.first())

    with true <- Feedback.allow?(user),
         :ok <- Feedback.submit(user, kind, params) do
      json(conn, %{status: "ok"})
    else
      false -> conn |> put_status(429) |> json(%{error: "rate_limited"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})
    end
  end

  def create(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid_kind"})
end
