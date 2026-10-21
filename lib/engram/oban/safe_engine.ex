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

  It also re-sends a job's insert notification after the surrounding
  `Engram.Repo` transaction commits, when the notifier is `Oban.Notifiers.PG`
  (clustered nodes, config/runtime.exs). PG delivers at once, unlike the
  Postgres notifier's on-commit NOTIFY, so Oban's own notification reaches a
  producer before the row is visible and the job would wait for the leader's
  next stager tick (`stage_interval`, 5s). Most enqueues happen inside a write
  transaction (`Notes.ContentCommit`). A rolled-back insert is not re-sent.
  The re-send rides `Engram.Repo.after_commit/1`, so a transaction that does
  not own that queue (a bare `Repo.transaction/1`) gets it immediately: no
  better, no worse than Oban's own.

  Every other callback delegates to `Oban.Engines.Basic`, generated from the
  `Oban.Engine` behaviour so an Oban upgrade that adds a callback is picked up
  (and `exception_egress_test.exs` fails if one is ever missed).
  """
  @behaviour Oban.Engine

  alias Engram.Logger.SafeException
  alias Oban.Engines.Basic

  @sanitizing [discard_job: 2, error_job: 3, cancel_job: 2]
  @renotifying [insert_job: 3, insert_all_jobs: 3]

  Code.ensure_compiled!(Basic)

  for {fun, arity} <- Oban.Engine.behaviour_info(:callbacks),
      {fun, arity} not in @sanitizing,
      {fun, arity} not in @renotifying,
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

  @impl Oban.Engine
  def insert_job(conf, changeset, opts) do
    with {:ok, job} <- Basic.insert_job(conf, changeset, opts) do
      renotify_after_commit(conf, [job])
      {:ok, job}
    end
  end

  @impl Oban.Engine
  def insert_all_jobs(conf, changesets, opts) do
    jobs = Basic.insert_all_jobs(conf, changesets, opts)
    renotify_after_commit(conf, jobs)
    jobs
  end

  # The same payload Oban.Engine.notify_trigger/2 sends.
  defp renotify_after_commit(
         %{notifier: {Oban.Notifiers.PG, _}, insert_trigger: true} = conf,
         jobs
       ) do
    payload = for job <- jobs, job.state == "available", uniq: true, do: %{queue: job.queue}

    if payload != [] and Engram.Repo.in_transaction?() do
      Engram.Repo.after_commit(fn -> Oban.Notifier.notify(conf, :insert, payload) end)
    end

    :ok
  end

  defp renotify_after_commit(_conf, _jobs), do: :ok

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
