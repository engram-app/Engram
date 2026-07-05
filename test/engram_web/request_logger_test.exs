defmodule EngramWeb.RequestLoggerTest do
  use ExUnit.Case, async: false

  alias Engram.Test.LogCapture
  alias EngramWeb.RequestLogger

  @sentinel_path "/api/notes/secret-folder/XYZZYZ-LOGTEST-CONFIDENTIAL.md"
  @sentinel_query "q=XYZZYZ-LOGTEST-USER-SEARCH"

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    RequestLogger.attach()

    on_exit(fn ->
      :telemetry.detach(:engram_request_logger)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  test "emits message with only method + status + duration — no path bytes" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: @sentinel_path,
      query_string: @sentinel_query,
      status: 401
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 5_000_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event, "expected a request log event, got: #{inspect(events)}"

    msg = render_msg(event.msg)
    assert msg =~ "GET"
    assert msg =~ "401"
    assert msg =~ ~r/\d+ms/

    refute msg =~ "XYZZYZ", "leaked path content into message body: #{inspect(msg)}"
  end

  test "routes request_path + request_query through metadata where the redact filter scrubs them" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: @sentinel_path,
      query_string: @sentinel_query,
      status: 200
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 1_000_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event

    assert event.meta[:request_path] == "[REDACTED]"
    assert event.meta[:request_query] == "[REDACTED]"
    refute inspect(event.meta) =~ "XYZZYZ"
  end

  test "passes through method, status, user_id as structured metadata (not redacted)" do
    user = %{id: 42}

    conn = %Plug.Conn{
      method: "POST",
      request_path: "/api/notes",
      query_string: "",
      status: 201,
      assigns: %{current_user: user}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 2_000_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event

    assert event.meta[:method] == "POST"
    assert event.meta[:status] == 201
    assert event.meta[:user_id] == 42
  end

  test "tolerates absent current_user assign (anonymous request)" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: "/api/health",
      query_string: "",
      status: 200,
      assigns: %{}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 100_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event
    assert event.meta[:user_id] == nil
  end

  test "captures x-amzn-mtls-clientcert-subject header into metadata when ALB injects it" do
    # ALB in passthrough or verify mode injects this header on successful
    # mTLS handshake with a CF-presented per-hostname AOP cert. The
    # value is the leaf cert's subject DN. Logging it lets us confirm
    # CF→ALB mTLS is intact from the backend side without poking the
    # ALB directly.
    subject = "CN=cloudflare-origin-pull.engram.page,O=Engram,OU=Origin-Auth"

    conn = %Plug.Conn{
      method: "GET",
      request_path: "/api/health",
      query_string: "",
      status: 200,
      assigns: %{},
      req_headers: [{"x-amzn-mtls-clientcert-subject", subject}]
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 100_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event
    assert event.meta[:mtls_clientcert_subject] == subject
  end

  test "metadata mtls_clientcert_subject is nil when no ALB header present (dev/test/AOP off)" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: "/api/health",
      query_string: "",
      status: 200,
      assigns: %{},
      req_headers: []
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 100_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event
    assert event.meta[:mtls_clientcert_subject] == nil
  end

  test "records the matched controller#action as route metadata so the endpoint is visible" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: @sentinel_path,
      query_string: @sentinel_query,
      status: 200,
      private: %{phoenix_controller: EngramWeb.NotesController, phoenix_action: :show}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 1_000_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event

    # The route is the matched template, not the actual path — never carries
    # user content (unlike request_path, which legitimately embeds note titles).
    assert event.meta[:route] == "EngramWeb.NotesController#show"
    refute inspect(event.meta[:route]) =~ "XYZZYZ"
  end

  test "route metadata is nil when no controller matched (static / 404 / plug-only)" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: "/nope",
      query_string: "",
      status: 404,
      private: %{}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :endpoint, :stop],
          %{duration: 100_000},
          %{conn: conn}
        )
      end)

    event = find_request_event(events)
    assert event
    assert event.meta[:route] == nil
  end

  test "escalates a 5xx response to :error level (a 500 flood is visible to level alerts)" do
    conn = %Plug.Conn{method: "GET", request_path: "/api/notes", query_string: "", status: 500}

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000_000}, %{conn: conn})
      end)

    event = find_request_event(events)
    assert event
    assert event.level == :error
  end

  test "downgrades a 2xx response to :info level" do
    conn = %Plug.Conn{method: "GET", request_path: "/api/notes", query_string: "", status: 200}

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000_000}, %{conn: conn})
      end)

    event = find_request_event(events)
    assert event
    assert event.level == :info
  end

  test "suppresses successful health-check probes (ALB hits these every 1-2s — pure noise)" do
    for action <- [:index, :deep] do
      conn = %Plug.Conn{
        method: "GET",
        request_path: "/health",
        query_string: "",
        status: 200,
        private: %{phoenix_controller: EngramWeb.HealthController, phoenix_action: action}
      }

      {_, events} =
        LogCapture.with_events(fn ->
          :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000_000}, %{conn: conn})
        end)

      refute find_request_event(events),
             "expected no log for successful HealthController##{action}, got: #{inspect(events)}"
    end
  end

  test "still logs a degraded (non-2xx) health check so a failing readiness probe stays visible" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: "/health/deep",
      query_string: "",
      status: 503,
      private: %{phoenix_controller: EngramWeb.HealthController, phoenix_action: :deep}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000_000}, %{conn: conn})
      end)

    event = find_request_event(events)
    assert event, "a degraded (503) health check must still log"
    assert event.level == :error
  end

  test "logs a router_dispatch exception with route + bounded error_kind (no secret leak)" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: @sentinel_path,
      query_string: "",
      status: 500,
      private: %{phoenix_controller: EngramWeb.NotesController, phoenix_action: :show}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :router_dispatch, :exception],
          %{duration: 1_000_000},
          %{
            conn: conn,
            kind: :error,
            reason: %RuntimeError{message: "XYZZYZ-secret"},
            stacktrace: []
          }
        )
      end)

    event =
      Enum.find(events, fn e -> render_msg(e.msg) =~ "request exception" end)

    assert event, "expected a request-exception log event"
    assert event.level == :error
    assert event.meta[:route] == "EngramWeb.NotesController#show"
    assert event.meta[:error_kind] == RuntimeError
    refute inspect(event.meta) =~ "XYZZYZ"
  end

  test "successful request stamps category=:http and loki_ship=false" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: "/api/notes",
      query_string: "",
      status: 200,
      private: %{phoenix_controller: EngramWeb.NotesController, phoenix_action: :index},
      assigns: %{}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 0}, %{conn: conn})
      end)

    event = find_request_event(events)
    assert event
    assert event.level == :info
    assert event.meta[:category] == :http
    assert event.meta[:loki_ship] == false
  end

  test "5xx request stamps category=:http and loki_ship=true (error level ships to Loki)" do
    conn = %Plug.Conn{
      method: "POST",
      request_path: "/api/notes",
      query_string: "",
      status: 500,
      private: %{phoenix_controller: EngramWeb.NotesController, phoenix_action: :create},
      assigns: %{}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 0}, %{conn: conn})
      end)

    event = find_request_event(events)
    assert event
    assert event.level == :error
    assert event.meta[:category] == :http
    assert event.meta[:loki_ship] == true
  end

  test "router_dispatch exception stamps category=:http and loki_ship=true" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: "/api/notes/x.md",
      query_string: "",
      status: 500,
      private: %{phoenix_controller: EngramWeb.NotesController, phoenix_action: :show}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute(
          [:phoenix, :router_dispatch, :exception],
          %{duration: 0},
          %{conn: conn, kind: :error, reason: %RuntimeError{message: "boom"}, stacktrace: []}
        )
      end)

    event = Enum.find(events, fn e -> render_msg(e.msg) =~ "request exception" end)
    assert event
    assert event.meta[:category] == :http
    assert event.meta[:loki_ship] == true
  end

  test "surfaces a plug-set reject_reason as metadata on the existing request log line" do
    # VaultPlug (and peers) assign :reject_reason instead of emitting a second
    # log, so the rejection reason rides the single request-stop line rather than
    # doubling Loki ingest on the 4xx path.
    conn = %Plug.Conn{
      method: "POST",
      request_path: "/api/notes",
      query_string: "",
      status: 404,
      assigns: %{reject_reason: "vault_id_malformed"}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 0}, %{conn: conn})
      end)

    event = find_request_event(events)
    assert event
    assert event.meta[:reason] == "vault_id_malformed"
  end

  test "omits reason metadata when no plug set one (normal request)" do
    conn = %Plug.Conn{
      method: "GET",
      request_path: "/api/notes",
      query_string: "",
      status: 200,
      assigns: %{}
    }

    {_, events} =
      LogCapture.with_events(fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 0}, %{conn: conn})
      end)

    event = find_request_event(events)
    assert event
    assert event.meta[:reason] == nil
  end

  defp find_request_event(events) do
    Enum.find(events, fn e ->
      msg = render_msg(e.msg)
      msg =~ ~r/^[A-Z]+ \d+ in \d+ms$/
    end)
  end

  defp render_msg({:string, s}), do: IO.iodata_to_binary(s)
  defp render_msg({:report, _}), do: ""
  defp render_msg(other), do: to_string(other)
end
