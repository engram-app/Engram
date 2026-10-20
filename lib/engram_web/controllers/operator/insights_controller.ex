defmodule EngramWeb.Operator.InsightsController do
  @moduledoc """
  Read-only operator insights (`Engram.Insights`), every tenant. Behind
  `EngramWeb.Plugs.RequireOperator`; GET only. Not in the public API spec.
  """
  use EngramWeb, :controller

  alias Engram.Insights
  alias EngramWeb.Plugs.Halt

  def index(conn, _params), do: json(conn, %{reports: Insights.reports()})

  # `?days=N` bounds the report (default 180, clamped to 1..730).
  def show(conn, %{"report" => name} = params) do
    if name in Insights.reports(),
      do: json(conn, Insights.report(name, :all, days: days(params["days"]))),
      else: Halt.json(conn, 404, %{error: "not_found"})
  end

  defp days(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp days(_raw), do: nil

  def timeline(conn, %{"user_id" => user_id}) do
    with {:ok, id} <- Ecto.UUID.cast(user_id),
         %{} = timeline <- Insights.timeline(id, :all) do
      json(conn, timeline)
    else
      _ -> Halt.json(conn, 404, %{error: "not_found"})
    end
  end
end
