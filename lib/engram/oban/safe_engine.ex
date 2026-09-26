defmodule Engram.Oban.SafeEngine do
  @moduledoc """
  `Oban.Engines.Basic`, except a failed job's error is sanitized before it is
  written to `oban_jobs.errors`.

  Oban stores `Exception.format/3` of the failure (`Oban.Job.format_attempt/1`)
  as plain text in Postgres. A worker that crashes matching on a decrypted
  note, or returns `{:error, term}` (wrapped in an `Oban.PerformError` that
  inspects it), would persist that term. The three callbacks that record an
  error run `unsaved_error` through `Engram.Logger.SafeException` first; the
  stored text keeps the type, an allowlisted message, and file/line frames.

  Every other callback delegates to `Oban.Engines.Basic`, generated from the
  `Oban.Engine` behaviour so an Oban upgrade that adds a callback is picked up
  (and `exception_egress_test.exs` fails if one is ever missed).
  """
  @behaviour Oban.Engine

  alias Engram.Logger.SafeException
  alias Oban.Engines.Basic

  @sanitizing [discard_job: 2, error_job: 3, cancel_job: 2]

  Code.ensure_compiled!(Basic)

  for {fun, arity} <- Oban.Engine.behaviour_info(:callbacks),
      {fun, arity} not in @sanitizing,
      function_exported?(Basic, fun, arity) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl Oban.Engine
    def unquote(fun)(unquote_splicing(args)), do: Basic.unquote(fun)(unquote_splicing(args))
  end

  @impl Oban.Engine
  def discard_job(conf, job), do: Basic.discard_job(conf, sanitize_job(job))

  @impl Oban.Engine
  def error_job(conf, job, seconds), do: Basic.error_job(conf, sanitize_job(job), seconds)

  @impl Oban.Engine
  def cancel_job(conf, job), do: Basic.cancel_job(conf, sanitize_job(job))

  @doc "Rewrite a job's `unsaved_error` so `Oban.Job.format_attempt/1` renders no term."
  @spec sanitize_job(Oban.Job.t()) :: Oban.Job.t()
  def sanitize_job(
        %Oban.Job{unsaved_error: %{kind: kind, reason: reason, stacktrace: stack} = unsaved} = job
      ) do
    {safe, safe_stack} = SafeException.to_safe_exception(kind, reason, stack)
    %{job | unsaved_error: %{unsaved | kind: :error, reason: safe, stacktrace: safe_stack}}
  end

  def sanitize_job(job), do: job
end
