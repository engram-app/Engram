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
