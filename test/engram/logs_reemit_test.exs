defmodule Engram.LogsReemitTest do
  use Engram.DataCase, async: false
  import ExUnit.CaptureLog
  alias Engram.Logs

  test "re-emits client logs through Logger with conn_id metadata" do
    user = insert(:user)

    log =
      capture_log(fn ->
        {:ok, 1} =
          Logs.insert_logs(user, [
            %{
              "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "level" => "warn",
              "category" => "channel",
              "message" => "WS closed before open",
              "conn_id" => "c1",
              "device_id" => "d1"
            }
          ])
      end)

    assert log =~ "WS closed before open"
    assert log =~ "c1"
  end

  test "diagnostic entries get loki_ship: true even at info level" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_test_handler

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    {:ok, 1} =
      Logs.insert_logs(user, [
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "info",
          "category" => "vault",
          "message" => "modify path=a.md",
          "diagnostic" => true,
          "conn_id" => "c1"
        }
      ])

    assert_receive {^ref, _level, meta}, 1000
    assert meta[:loki_ship] == true
    # The STRING is what Fluent Bit routes on; the boolean alone shipped
    # nothing for months (engram-app/engram-infra#1095).
    assert meta[:ship] == "loki"
    assert meta[:category] == :client
  end

  # `diagnostic` is a client-controlled boolean off the request body. Before the
  # paired routing rule existed it was a flag nothing read, so an unbounded
  # batch was absorbed silently; it is a live Loki-ingest lever now. Entries
  # past the cap are info lines Loki would drop, so they stay in the DB only.
  test "only the first @max_diagnostic_ships entries of a batch force a Loki ship" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_cap_handler

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    entries =
      for i <- 1..120 do
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "info",
          "category" => "vault",
          "message" => "modify #{i}",
          "diagnostic" => true,
          # The shared handler below only forwards entries with this conn_id.
          "conn_id" => "c1"
        }
      end

    {:ok, 120} = Logs.insert_logs(user, entries)

    shipped =
      Enum.reduce(1..121, 0, fn _, acc ->
        receive do
          {^ref, _level, meta} -> if meta[:ship] == "loki", do: acc + 1, else: acc
        after
          200 -> acc
        end
      end)

    assert shipped == 100
  end

  test "client-originated 'error' severity is capped at :warning so it never inflates the backend error-rate alert, but the original severity survives in metadata" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_severity_test_handler

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    {:ok, 1} =
      Logs.insert_logs(user, [
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "error",
          "category" => "channel",
          "message" => "rate_limited",
          "conn_id" => "c2",
          "device_id" => "d1"
        }
      ])

    assert_receive {^ref, level, meta}, 1000
    assert level == :warning
    assert meta[:category] == :client
    assert meta[:client_severity] == "error"
  end

  # Web and plugin both ship through this pipe; without the platform on the
  # Loki line a web-only alert (broken SPA API requests) cannot be written.
  test "client platform reaches the Loki re-emit metadata" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_platform_test_handler

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    {:ok, 1} =
      Logs.insert_logs(user, [
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "error",
          "category" => "api_request",
          "message" => "network_error POST /folders/:seg",
          "platform" => "web",
          "conn_id" => "c1"
        }
      ])

    assert_receive {^ref, _level, meta}, 1000
    assert meta[:platform] == "web"
  end

  # A web network_error says only "Failed to fetch"; the context the SPA sends
  # beside it (browser, timing, attempt) is what tells causes apart, and it is
  # only useful as Loki metadata (`| metadata_browser="Chrome 155"`).
  describe "network context" do
    defp reemit_context(context) do
      user = insert(:user)
      parent = self()
      ref = make_ref()
      handler_id = :logs_reemit_context_handler

      :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
      on_exit(fn -> :logger.remove_handler(handler_id) end)

      {:ok, 1} =
        Logs.insert_logs(user, [
          %{
            "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "level" => "error",
            "category" => "api_request",
            "message" => "network_error GET https://api.engram.page/me",
            "platform" => "web",
            "conn_id" => "c1",
            "context" => context
          }
        ])

      assert_receive {^ref, _level, meta}, 1000
      meta
    end

    test "allowlisted fields reach the re-emit metadata" do
      meta =
        reemit_context(%{
          "browser" => "Chrome 155",
          "went_offline" => true,
          "attempt" => 2,
          "elapsed_ms" => 812,
          "error_name" => "TypeError",
          "error_message" => "Failed to fetch",
          "visibility" => "visible",
          "effective_type" => "4g"
        })

      assert meta[:browser] == "Chrome 155"
      assert meta[:went_offline] == true
      assert meta[:attempt] == 2
      assert meta[:elapsed_ms] == 812
      assert meta[:error_name] == "TypeError"
      assert meta[:error_message] == "Failed to fetch"
      assert meta[:visibility] == "visible"
      assert meta[:effective_type] == "4g"
    end

    test "unknown keys and out-of-shape values are dropped" do
      meta =
        reemit_context(%{
          "url" => "https://api.engram.page/notes/Medical/x.md",
          "browser" => String.duplicate("Chrome ", 50) <> "155",
          "went_offline" => "yes",
          "attempt" => 10_000,
          "elapsed_ms" => -1,
          "error_name" => "Medical/x.md",
          "error_message" => "net::ERR at https://api.engram.page/notes/Medical/x.md",
          "visibility" => "<script>",
          "effective_type" => "5g"
        })

      for key <-
            ~w(url browser went_offline attempt elapsed_ms error_name error_message visibility effective_type)a do
        refute Map.has_key?(meta, key), "#{key} passed through"
      end
    end

    # `false` is a value, not an absence: "did not go offline" is
    # exactly as much signal as one that is true.
    test "a false value survives" do
      meta = reemit_context(%{"went_offline" => false})
      assert Map.fetch(meta, :went_offline) == {:ok, false}
    end

    # A burst of the same network_error differs only in timing. Keying the
    # collapse on the whole context kept every one of them a separate line.
    test "identical errors collapse even though elapsed_ms differs" do
      user = insert(:user)
      parent = self()
      ref = make_ref()
      handler_id = :logs_reemit_context_handler

      :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
      on_exit(fn -> :logger.remove_handler(handler_id) end)

      entry = fn elapsed, message ->
        %{
          "level" => "error",
          "category" => "api_request",
          "message" => "network_error GET https://api.engram.page/me",
          "platform" => "web",
          "conn_id" => "c1",
          "context" => %{
            "browser" => "Chrome 155",
            "error_message" => message,
            "elapsed_ms" => elapsed
          }
        }
      end

      entries =
        for(ms <- 1..50, do: entry.(ms * 10, "Failed to fetch")) ++ [entry.(7, "other")]

      {:ok, 51} = Logs.insert_logs(user, entries)

      assert_receive {^ref, _level, burst}, 1000
      assert burst[:repeat] == 50
      assert burst[:error_message] == "Failed to fetch"
      # The range, so a burst of fast failures and one stall stay distinguishable.
      assert burst[:elapsed_ms] == 500
      assert burst[:elapsed_ms_min] == 10

      assert_receive {^ref, _level, other}, 1000
      assert other[:error_message] == "other"
      assert other[:elapsed_ms] == 7
      refute Map.has_key?(other, :elapsed_ms_min)
      refute_receive {^ref, _, _}, 100
    end

    # config.exs requires every metadata key we emit in :default_formatter's
    # list; these reach Logger through Keyword.merge, where credo's
    # MissedMetadataKeyInLoggerConfig cannot see them.
    test "every context key is a declared formatter metadata key" do
      declared = Application.fetch_env!(:logger, :default_formatter)[:metadata]
      assert Logs.context_metadata_keys() -- declared == []
    end

    test "a context that is not a map is ignored" do
      meta = reemit_context("browser=Chrome")
      refute Map.has_key?(meta, :browser)
    end
  end

  # The re-emit is the surface that is greppable in ONE Loki query without the
  # read-only DB bastion, so it is where "does this signal cover the whole
  # fleet, or only opted-in users?" actually gets asked. Persisting `forced` to
  # client_logs alone would leave the on-call path as blind as before.
  test "forced provenance reaches the Loki re-emit metadata, not just the DB" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_forced_test_handler

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    {:ok, 2} =
      Logs.insert_logs(user, [
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "warn",
          "category" => "sync",
          "message" => "replay_produced_no_files applied=1 files=0",
          "conn_id" => "c1",
          "forced" => true
        },
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "warn",
          "category" => "sync",
          "message" => "ordinary warning",
          "conn_id" => "c2"
        }
      ])

    metas =
      for _ <- 1..2 do
        assert_receive {^ref, _level, meta}, 1000
        {meta[:conn_id], meta[:forced]}
      end
      |> Map.new()

    assert metas["c1"] == true
    # Provenance, not severity: an ordinary warn must not claim the exemption.
    refute metas["c2"]
  end

  # :logger handler callback
  def log(%{level: level, meta: meta}, %{config: %{parent: parent, ref: ref}}) do
    if meta[:category] == :client and meta[:conn_id] in ["c1", "c2"] do
      send(parent, {ref, level, meta})
    end

    :ok
  end

  # Old plugins still in the field send raw paths in message and stack. The
  # scrub happens once, on ingest, so neither the client_logs row nor the
  # Loki re-emit carries them.
  test "paths in client message and stack are scrubbed before storage and re-emit" do
    user = insert(:user)

    log =
      capture_log(fn ->
        {:ok, 1} =
          Logs.insert_logs(user, [
            %{
              "level" => "error",
              "category" => "push",
              "message" =>
                "push failed: ENOENT: no such file, open '/Users/alice/Vault/Medical/canary-3b.md'",
              "stack" =>
                "Error: ENOENT open '/Users/alice/Vault/Medical/canary-3b.md'\n    at push (app.js:1:2)"
            }
          ])
      end)

    refute log =~ "canary-3b"
    refute log =~ "alice"

    row =
      Engram.Repo.one!(from(l in Engram.Logs.ClientLog, where: l.user_id == ^user.id),
        skip_tenant_check: true
      )

    refute row.message =~ "canary-3b"
    refute row.stack =~ "canary-3b"
    refute row.stack =~ "alice"
    assert row.stack =~ "at push (app.js:1:2)"
  end

  describe "what reaches stdout" do
    # Shaped like one prod batch from a syncing device (2026-10-17): mostly an
    # info trace line, plus one warning repeated per refused frame.
    defp prod_batch do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      entry = fn level, msg ->
        %{
          "ts" => now,
          "level" => level,
          "category" => "pull",
          "message" => msg,
          "conn_id" => "c2"
        }
      end

      List.duplicate(entry.("info", "rename-trace 2/3 SKIPPED (map already at target)"), 11) ++
        List.duplicate(entry.("warn", "Index frame refused by server (rate_limited)"), 6) ++
        [
          entry.("warn", "crdt_create failed, enqueued for durable retry"),
          entry.("warn", "crdt_create dropped (overflow) without deliver"),
          entry.("error", "pull failed: timeout")
        ]
    end

    defp emitted_lines(fun) do
      parent = self()
      ref = make_ref()
      handler_id = :logs_reemit_lines_handler
      previous_level = Logger.level()
      Logger.configure(level: :info)
      :logger.add_handler(handler_id, __MODULE__.Lines, %{config: %{parent: parent, ref: ref}})

      try do
        fun.()
      after
        :logger.remove_handler(handler_id)
        Logger.configure(level: previous_level)
      end

      collect_lines(ref, [])
    end

    defp collect_lines(ref, acc) do
      receive do
        {^ref, line} -> collect_lines(ref, [line | acc])
      after
        200 -> Enum.reverse(acc)
      end
    end

    test "info lines that Loki drops are not written; identical lines collapse with a count" do
      user = insert(:user)
      lines = emitted_lines(fn -> assert {:ok, 20} = Logs.insert_logs(user, prod_batch()) end)

      IO.puts("[reemit-bench] stdout lines for the 20-entry prod batch: #{length(lines)}")
      assert length(lines) == 4
      refute Enum.any?(lines, &(&1.msg =~ "rename-trace"))

      refused = Enum.find(lines, &(&1.msg =~ "Index frame refused"))
      assert refused.meta[:repeat] == 6
      assert refused.meta[:loki_ship] == true
      assert Enum.all?(lines -- [refused], &(&1.meta[:repeat] == nil))
    end

    test "every entry is still persisted, including the ones not written to stdout" do
      user = insert(:user)
      _ = emitted_lines(fn -> {:ok, 20} = Logs.insert_logs(user, prod_batch()) end)

      count =
        Engram.Repo.aggregate(
          from(l in Engram.Logs.ClientLog, where: l.user_id == ^user.id),
          :count,
          skip_tenant_check: true
        )

      assert count == 20
    end

    test "a diagnostic info entry is still written, and repeats of it collapse" do
      user = insert(:user)
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      diag = %{
        "ts" => now,
        "level" => "info",
        "category" => "vault",
        "message" => "modify",
        "diagnostic" => true,
        "conn_id" => "c2"
      }

      lines = emitted_lines(fn -> {:ok, 3} = Logs.insert_logs(user, List.duplicate(diag, 3)) end)

      assert [%{meta: meta}] = lines
      assert meta[:ship] == "loki"
      assert meta[:repeat] == 3
    end
  end

  defmodule Lines do
    def log(%{msg: msg, meta: meta}, %{config: %{parent: parent, ref: ref}}) do
      if meta[:category] == :client and meta[:conn_id] == "c2" do
        send(parent, {ref, %{msg: render(msg), meta: meta}})
      end

      :ok
    end

    defp render({:string, s}), do: IO.iodata_to_binary(s)
    defp render({:report, r}), do: inspect(r)
    defp render({fmt, args}), do: :io_lib.format(fmt, args) |> IO.iodata_to_binary()
  end

  # Scrub BEFORE truncating: a quoted path that straddles the length cap would
  # otherwise lose its closing quote and pass every rule half-intact.
  test "a path straddling the message cap is not stored half-scrubbed" do
    user = insert(:user)
    pad = String.duplicate("x", 7_980)

    {:ok, 1} =
      Logs.insert_logs(user, [
        %{
          "level" => "error",
          "category" => "push",
          "message" => pad <> " open 'Medical/Divorce settlement draft.md'"
        }
      ])

    row =
      Engram.Repo.one!(from(l in Engram.Logs.ClientLog, where: l.user_id == ^user.id),
        skip_tenant_check: true
      )

    refute row.message =~ "Medical"
    refute row.message =~ "Divorce"
    assert String.length(row.message) <= 8_000
  end
end
