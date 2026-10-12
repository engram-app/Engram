defmodule EngramWeb.FeedbackController do
  use EngramWeb, :controller

  alias Engram.Feedback

  # Each submit is a billed PostHog event carrying up to 2,000 chars of free
  # text, and this scope skips the API RPS budget, so it gets its own cap.
  # Real use is a handful per user ever (one survey, one cancel, some notes).
  @hourly_limit 20

  def create(conn, %{"kind" => kind} = params) when is_binary(kind) do
    user = conn.assigns.current_user
    # Server-stamped, so a client cannot send a misleading one.
    params = Map.put(params, "user_agent", conn |> get_req_header("user-agent") |> List.first())

    with {:allow, _} <-
           EngramWeb.RateLimiter.hit(
             "feedback:#{user.id}",
             :timer.hours(1),
             @hourly_limit,
             :feedback
           ),
         :ok <- Feedback.submit(user, kind, params) do
      json(conn, %{status: "ok"})
    else
      {:deny, _} -> conn |> put_status(429) |> json(%{error: "rate_limited"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})
    end
  end

  def create(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid_kind"})
end
