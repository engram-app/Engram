defmodule EngramWeb.Plugs.CacheRawBody do
  @moduledoc """
  Caches the raw request body in conn.assigns[:raw_body] for webhook signature verification.
  Must be used as a Plug.Parsers body_reader.

  Every read runs in an `http.request.body_read` span (`read_traced/2`). The
  Bandit request span starts once the headers are parsed, BEFORE the body
  arrives, so a client that sends its body slowly shows up as seconds of
  unexplained time before the first DB query (2026-10-24 speed audit:
  0.5-15 s on POSTs, the process parked in `Plug.Conn.read_body`). This span
  makes that wait visible and names its size.
  """

  alias OpenTelemetry.SemConv.Incubating.HTTPAttributes

  require OpenTelemetry.Tracer, as: Tracer

  def read_body(conn, opts) do
    case read_traced(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.assign(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, body, conn} ->
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `Plug.Conn.read_body/2` inside an `http.request.body_read` span carrying
  `http.request.body.size` (bytes this call read) and
  `engram.body_read.result` (`ok`, `more` or `error`). The one body read
  every parsed request and the raw attachment upload go through.
  """
  def read_traced(conn, opts) do
    Tracer.with_span "http.request.body_read" do
      result = Plug.Conn.read_body(conn, opts)

      {status, bytes} =
        case result do
          {:ok, body, _conn} -> {"ok", byte_size(body)}
          {:more, body, _conn} -> {"more", byte_size(body)}
          {:error, _reason} -> {"error", 0}
        end

      Tracer.set_attributes(%{
        HTTPAttributes.http_request_body_size() => bytes,
        "engram.body_read.result": status
      })

      result
    end
  end
end
