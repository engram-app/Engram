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

  alias Engram.Logger.Metadata

  @secret "Dear diary, the biopsy came back positive."

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

  # The counterweight: a type filter that dropped every message would make the
  # log useless, and on-call would route around it.
  describe "allowlisted types keep their message" do
    test "Postgrex.Error keeps the SQLSTATE, which is the useful part" do
      e = %Postgrex.Error{
        postgres: %{
          code: :numeric_value_out_of_range,
          message: "bigint out of range",
          severity: "ERROR",
          pg_code: "22003"
        }
      }

      assert Metadata.safe_reason(e) =~ "bigint out of range"
    end

    test "DBConnection.ConnectionError keeps its message" do
      assert Metadata.safe_reason(%DBConnection.ConnectionError{message: "tcp recv: closed"}) =~
               "tcp recv"
    end
  end

  # A new exception type — from Elixir, or a dependency bump — must default to
  # safe. This is the whole reason it is an allowlist.
  test "an unknown exception type defaults to class-only" do
    assert Metadata.safe_reason(%RuntimeError{message: @secret}) == "RuntimeError"
  end
end
