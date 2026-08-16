defmodule Engram.Logger.MetadataSafeReasonTest do
  @moduledoc """
  `safe_reason/1` is the one seam that decides whether a rescued exception's
  message may be logged.

  It exists because moving a message from the log body into metadata does not
  redact it: `RedactFilter` scrubs by KEY, and `:error` / `:reason` / `:message`
  are not in its set — so Loki and CloudWatch print metadata verbatim. The only
  thing standing between a `CaseClauseError` over a note body and CloudWatch is
  this function.
  """
  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.Logger.Metadata

  @secret "Dear diary, the biopsy came back positive."

  # `String.to_integer(@secret)` on a literal makes the compiler prove the call
  # fails and emit "the call to binary_to_integer/1 will fail with a 'badarg'
  # exception" — which --warnings-as-errors turns into a CI failure. It compiled
  # clean locally only because _build was warm and these files were already
  # built; CI compiles fresh. Routing through Enum.random/1 hides the value's
  # type from the compiler while returning exactly it.
  defp opaque_secret, do: Enum.random([@secret])

  # Every one of these renders inspect(term) in its message/1, and every one is
  # reachable from a rescue that has note content in scope.
  describe "exceptions that inspect a term contribute their class only" do
    test "CaseClauseError" do
      e = %CaseClauseError{term: {:parsed, @secret}}
      assert Metadata.safe_reason(e) == "CaseClauseError"
    end

    test "MatchError" do
      e = %MatchError{term: @secret}
      assert Metadata.safe_reason(e) == "MatchError"
    end

    test "KeyError" do
      e = %KeyError{key: :missing, term: %{"content" => @secret}}
      assert Metadata.safe_reason(e) == "KeyError"
    end

    test "the raw message really would have leaked" do
      e = %CaseClauseError{term: {:parsed, @secret}}

      assert Exception.message(e) =~ "biopsy"
      refute Metadata.safe_reason(e) =~ "biopsy"
    end
  end

  # Round 5 traced every allowlisted type's message/1 into deps/ and executed
  # them. Three of the original five rendered user data. These are the ones
  # that were WRONG, and they are pinned so the allowlist cannot regrow.
  describe "types whose message/1 renders a value are NOT allowlisted" do
    # The whole %Note{} — `inspect(changeset.data)`. This is the round-3 defect
    # (Exception.message/1 renders inspect(term)) reintroduced by name in the
    # fix for it.
    test "Ecto.StaleEntryError does not render the struct it holds" do
      note = %Engram.Notes.Note{content: @secret, title: "Biopsy", path: "Medical/biopsy.md"}
      # Built via exception/1, which is what computes the leaky message.
      e = Ecto.StaleEntryError.exception(action: :update, changeset: %Ecto.Changeset{data: note})

      # The message really does carry it — otherwise this tests nothing.
      assert Exception.message(e) =~ "biopsy"

      # The struct really does inspect its plaintext — so this measures the
      # filter, not an empty base.
      assert inspect(note) =~ "biopsy"
      refute Metadata.safe_reason(e) =~ "biopsy"
      refute Metadata.safe_reason(e) =~ "Medical"
    end

    # Renders the query with pinned params verbatim.
    test "Ecto.QueryError does not render a pinned parameter" do
      # A real query with a pinned param — Inspect.Ecto.Query renders it
      # verbatim into the message, which is the leak.
      query = from(n in Engram.Notes.Note, where: n.kind == ^@secret)
      e = Ecto.QueryError.exception(message: "boom", query: query)

      assert Exception.message(e) =~ "biopsy"
      refute Metadata.safe_reason(e) =~ "biopsy"
    end

    # message + the SQL + Postgres DETAIL ("Failing row contains (...)").
    test "Postgrex.Error renders codes, never the failing row or the query" do
      e = %Postgrex.Error{
        postgres: %{
          code: :check_violation,
          message: ~s(new row violates check constraint, value "#{@secret}"),
          detail: "Failing row contains (1, #{@secret}, Medical/biopsy.md).",
          severity: "ERROR",
          pg_code: "23514"
        },
        query: "INSERT INTO notes (content) VALUES ('#{@secret}')"
      }

      rendered = Metadata.safe_reason(e)

      refute rendered =~ "biopsy"
      refute rendered =~ "Medical"
      refute rendered =~ "INSERT"
      # ...while keeping what a responder greps for.
      assert rendered =~ "23514"
      assert rendered =~ "check_violation"
      assert rendered =~ "ERROR"
    end
  end

  # The counterweight: a type filter that dropped every message would make the
  # log useless, and on-call would route around it.
  describe "allowlisted types keep their message" do
    test "Ecto.ConstraintError keeps its constraint name" do
      e = %Ecto.ConstraintError{
        type: :unique,
        constraint: "notes_path_hmac_index",
        message: "constraint error: notes_path_hmac_index (unique_constraint)"
      }

      assert Metadata.safe_reason(e) =~ "notes_path_hmac_index"
    end

    test "DBConnection.ConnectionError keeps its message" do
      assert Metadata.safe_reason(%DBConnection.ConnectionError{message: "tcp recv: closed"}) =~
               "tcp recv"
    end
  end

  # A rescue always binds a struct, but this is a public helper on a shared
  # logging module and its @spec invites `catch :exit, reason`. Raising from
  # inside an isolation helper defeats the isolation.
  # A filter that renders everything "unknown" gets routed around. Atoms are the
  # most common reason shape here and cannot carry note content.
  describe "atoms survive, because they are the useful case" do
    test "a bare reason atom renders" do
      assert Metadata.safe_reason(:not_found) == ":not_found"
      assert Metadata.safe_reason(:version_conflict) == ":version_conflict"
      assert Metadata.safe_reason(nil) == "nil"
    end
  end

  # A stacktrace is NOT "module/function/arity". BEAM puts the failing call's
  # actual ARGUMENT LIST in the top frame for FunctionClauseError,
  # UndefinedFunctionError and any BIF/NIF badarg, and
  # Exception.format_stacktrace/1 inspects each at :printable_limit (4096) —
  # so ~4 KB of a note body printed right next to the safe_reason/1 call that
  # had just suppressed it.
  describe "format_location/1 renders where, never what" do
    test "a real FunctionClauseError's arguments do not survive" do
      # Raised for real so the stacktrace is BEAM's, not a fixture.
      {:error, stacktrace} =
        try do
          String.to_integer(opaque_secret())
        rescue
          _ -> {:error, __STACKTRACE__}
        end

      # The unsafe formatter really does carry it — otherwise this proves nothing.
      assert Exception.format_stacktrace(stacktrace) =~ "biopsy"

      located = Metadata.format_location(stacktrace)
      refute located =~ "biopsy"
      refute located =~ @secret
      # ...while still saying where. (String.to_integer/1 inlines to the BIF,
      # so the top frame is :erlang.binary_to_integer/1 — which is the point:
      # a real BEAM stacktrace, not a fixture.)
      assert located =~ "binary_to_integer/1"
    end

    test "handles a malformed or empty stacktrace without raising" do
      assert Metadata.format_location([]) == ""
      assert is_binary(Metadata.format_location(:not_a_stacktrace))
      assert is_binary(Metadata.format_location([:garbage]))
    end
  end

  # An exit reason is the other way a stacktrace — and its arguments — reach a
  # log. A crashed GenServer exits with `{exception, stacktrace}`, and a call
  # timeout exits with `{:timeout, {GenServer, :call, [pid, request, _]}}` where
  # `request` on these paths is a Yjs frame or note content.
  describe "safe_exit_reason/1 keeps the shape, drops the values" do
    test "an exception+stacktrace exit does not carry the arguments" do
      {:error, stacktrace} =
        try do
          String.to_integer(opaque_secret())
        rescue
          _ -> {:error, __STACKTRACE__}
        end

      reason = {%ArgumentError{message: @secret}, stacktrace}

      # Both halves really would have leaked.
      assert inspect(reason) =~ "biopsy"

      rendered = Metadata.safe_exit_reason(reason)
      refute rendered =~ "biopsy"
      assert rendered =~ "ArgumentError"
      assert rendered =~ "binary_to_integer/1"
    end

    test "a GenServer call timeout drops the request payload" do
      reason = {:timeout, {GenServer, :call, [self(), {:apply, @secret}, 5000]}}

      assert inspect(reason) =~ "biopsy"

      rendered = Metadata.safe_exit_reason(reason)
      refute rendered =~ "biopsy"
      assert rendered =~ "GenServer.call/3"
    end

    test "ordinary exit shapes stay readable" do
      assert Metadata.safe_exit_reason(:normal) == ":normal"
      assert Metadata.safe_exit_reason(:noproc) == ":noproc"
      assert Metadata.safe_exit_reason({:shutdown, @secret}) == ":shutdown"
      assert is_binary(Metadata.safe_exit_reason("weird"))
    end
  end

  # `{:error, :not_found}` is the most common reason shape in this codebase. The
  # tag is safe and useful; the payload is where a %Note{} or a Yjs frame rides.
  describe "tuple reasons keep their tag, drop their payload" do
    test "the tag renders and the payload does not" do
      assert Metadata.safe_reason({:error, :not_found}) == ":error"
      assert Metadata.safe_reason({:notes_cap_reached, 100, 50}) == ":notes_cap_reached"

      note = %Engram.Notes.Note{content: @secret, path: "Medical/biopsy.md"}
      rendered = Metadata.safe_reason({:error, note})

      assert inspect({:error, note}) =~ "biopsy"
      refute rendered =~ "biopsy"
      refute rendered =~ "Medical"
    end

    test "a tuple with a non-atom tag is not rendered at all" do
      assert Metadata.safe_reason({@secret, 1}) == "unknown"
    end
  end

  # Storage errors are the case where dropping the payload would cost a real
  # diagnostic: a misconfigured MinIO secret is invisible without the S3 code.
  # An S3 code is a bare alphabetic identifier; a storage key is
  # "user/vault/<path>". The separator is what makes them separable.
  describe "storage errors keep their code, never their key" do
    test "an S3 error code survives" do
      assert Metadata.safe_reason({:http_error, 403, "SignatureDoesNotMatch"}) ==
               "http_error 403 SignatureDoesNotMatch"
    end

    test "a code buried in an XML body is extracted" do
      body = "<Error><Code>NoSuchKey</Code><Key>u1/v1/Medical/biopsy.md</Key></Error>"
      rendered = Metadata.safe_reason({:http_error, 404, body})

      assert rendered == "http_error 404 NoSuchKey"
      refute rendered =~ "Medical"
      refute rendered =~ "biopsy"
    end

    test "a body that is a storage key is not mistaken for a code" do
      rendered = Metadata.safe_reason({:http_error, 403, "u1/v1/Medical/biopsy.md"})

      assert rendered == "http_error 403"
      refute rendered =~ "Medical"
    end

    test "a prose message is not mistaken for a code" do
      assert Metadata.safe_reason({:http_error, 500, "the note Divorce draft failed"}) ==
               "http_error 500"
    end
  end

  describe "never raises, whatever it is handed" do
    test "a non-struct does not raise" do
      for value <- [:some_atom, {:error, "boom"}, "raw string", 42, nil, %{a: 1}] do
        assert is_binary(Metadata.safe_reason(value))
      end
    end
  end

  # A new exception type — from Elixir, or a dependency bump — must default to
  # safe. This is the whole reason it is an allowlist.
  test "an unknown exception type defaults to class-only" do
    assert Metadata.safe_reason(%RuntimeError{message: @secret}) == "RuntimeError"
  end
end
