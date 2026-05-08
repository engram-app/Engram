defmodule EngramWeb.HealthController do
  use EngramWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", version: Application.spec(:engram, :vsn) |> to_string()})
  end

  def deep(conn, _params) do
    checks = %{
      "postgres" => check_postgres(),
      "qdrant" => check_qdrant()
    }

    all_ok = Enum.all?(checks, fn {_k, v} -> v == "ok" end)
    status = if all_ok, do: "ok", else: "degraded"
    http_status = if all_ok, do: 200, else: 503

    conn
    |> put_status(http_status)
    |> json(%{status: status, checks: checks})
  end

  # T3.0.1 follow-up — never `inspect/1` an error reason into a JSON
  # response body. Postgrex / Mint structs interpolated via inspect can
  # carry connection strings, hostnames, or dependency-internal shapes.
  # `format_error/1` keeps the message low-cardinality and predictable.

  defp check_postgres do
    case Ecto.Adapters.SQL.query(Engram.Repo, "SELECT 1", []) do
      {:ok, _} -> "ok"
      {:error, reason} -> "error: #{format_error(reason)}"
    end
  rescue
    e -> "error: #{Exception.message(e)}"
  end

  defp check_qdrant do
    qdrant_url = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")

    case Req.get("#{qdrant_url}/healthz", receive_timeout: 5_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> "ok"
      {:ok, %{status: status}} -> "error: status #{status}"
      {:error, reason} -> "error: #{format_error(reason)}"
    end
  rescue
    e -> "error: #{Exception.message(e)}"
  end

  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(_), do: "internal"
end
