defmodule Engram.Logger.RedactFilterTest do
  use ExUnit.Case, async: true

  alias Engram.Logger.RedactFilter

  @sentinel "user-content-XYZZYZ-LOGTEST-SECRET"

  describe "filter/2" do
    test "redacts sensitive metadata keys, replacing with [REDACTED]" do
      event = build_event("blob delete failed", storage_key: @sentinel, reason: :enoent)
      result = RedactFilter.filter(event, [])

      assert result.meta.storage_key == "[REDACTED]"
      assert result.meta.reason == :enoent
    end

    test "redacts every key in the canonical sensitive list" do
      sensitive = [
        :content,
        :title,
        :tags,
        :path,
        :source_path,
        :note_path,
        :file_path,
        :attachment_path,
        :storage_key,
        :key,
        :folder,
        :folder_name,
        :query,
        :search_query,
        :request_path,
        :request_query,
        :email,
        :customer_email,
        :attachment_name,
        :filename,
        :name,
        :code_challenge,
        :code_verifier,
        :access_token,
        :refresh_token,
        :device_code,
        :authorization_header,
        :client_secret,
        :client_secret_hash
      ]

      meta = Map.new(sensitive, fn k -> {k, @sentinel} end)
      event = %{level: :info, msg: {:string, "x"}, meta: meta}
      result = RedactFilter.filter(event, [])

      for k <- sensitive do
        assert Map.fetch!(result.meta, k) == "[REDACTED]",
               "expected #{inspect(k)} to be redacted"
      end
    end

    test "passes through safe metadata keys untouched" do
      event =
        build_event("vault op",
          user_id: 42,
          vault_id: 7,
          note_id: 99,
          count: 5,
          reason: :timeout,
          status: :ok
        )

      result = RedactFilter.filter(event, [])

      assert result.meta.user_id == 42
      assert result.meta.vault_id == 7
      assert result.meta.note_id == 99
      assert result.meta.count == 5
      assert result.meta.reason == :timeout
      assert result.meta.status == :ok
    end

    test "does not modify the message body — call sites must use metadata, not interpolation" do
      event = build_event("blob failed key=#{@sentinel}", reason: :enoent)
      result = RedactFilter.filter(event, [])

      # Filter explicitly does not touch :msg — leak by interpolation is a call-site bug.
      # This test pins that contract so future maintainers understand the design.
      assert result.msg == {:string, "blob failed key=#{@sentinel}"}
    end

    test "tolerates missing metadata keys (only redacts what's present)" do
      event = build_event("safe message", user_id: 1)
      result = RedactFilter.filter(event, [])

      assert result.meta == %{user_id: 1}
    end

    test "handles binary values" do
      event = build_event("op", path: @sentinel)
      result = RedactFilter.filter(event, [])

      assert result.meta.path == "[REDACTED]"
    end

    test "handles non-binary values (lists, maps, atoms) by replacing wholesale" do
      event =
        build_event("op",
          tags: ["secret-tag", "other-secret"],
          content: %{nested: "secret"},
          title: :some_atom
        )

      result = RedactFilter.filter(event, [])

      assert result.meta.tags == "[REDACTED]"
      assert result.meta.content == "[REDACTED]"
      assert result.meta.title == "[REDACTED]"
    end

    test "returns event unchanged when meta has no sensitive keys" do
      event = build_event("safe", user_id: 1, vault_id: 2)
      original_meta = event.meta

      result = RedactFilter.filter(event, [])

      assert result.meta == original_meta
    end
  end

  describe "integration with :logger primary filter" do
    setup do
      :logger.add_primary_filter(:engram_redact_test, {&RedactFilter.filter/2, []})
      on_exit(fn -> :logger.remove_primary_filter(:engram_redact_test) end)
      :ok
    end

    test "scrubs metadata before any handler sees the event" do
      test_pid = self()

      handler_id = :test_capture

      handler_config = %{
        config: %{},
        formatter: {:logger_formatter, %{}}
      }

      :logger.add_handler(handler_id, :logger_std_h, handler_config)

      :logger.add_handler_filter(handler_id, :capture, {
        fn event, _ ->
          send(test_pid, {:log_event, event})
          :stop
        end,
        []
      })

      try do
        require Logger
        Logger.warning("blob failed", storage_key: @sentinel, reason: :enoent)

        # Filter on `:storage_key` — `async: true` with a global :logger
        # primary filter means concurrent tests' Logger calls also reach
        # this handler. Pre-T3.4 the test asserted on the FIRST event
        # received, which flaked under CI parallelism.
        event = wait_for_event_with_storage_key(500)

        assert event.meta.storage_key == "[REDACTED]"
        assert event.meta.reason == :enoent
      after
        :logger.remove_handler(handler_id)
      end
    end
  end

  defp wait_for_event_with_storage_key(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline)
  end

  defp do_wait(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:log_event, %{meta: %{storage_key: _}} = event} -> event
      {:log_event, _other} -> do_wait(deadline)
    after
      remaining -> flunk("no log event with :storage_key arrived within budget")
    end
  end

  defp build_event(msg, meta_kw) do
    %{
      level: :info,
      msg: {:string, msg},
      meta: Map.new(meta_kw)
    }
  end
end
