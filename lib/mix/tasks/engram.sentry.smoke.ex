defmodule Mix.Tasks.Engram.Sentry.Smoke do
  @shortdoc "Send one synthetic Sentry capture to verify the pipeline"

  @moduledoc """
  Smoke-test the Sentry pipeline end-to-end. Captures one event with a
  known marker so an operator can confirm the project ID + DSN + scrubber
  + ingestion all work.

  Run on staging:

      mix engram.sentry.smoke

  Then check the Sentry project for an event with
  `tags.smoke_marker = "engram.sentry.smoke"`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    # `result: :sync` posts the envelope before returning. The default (`:none`)
    # hands it to Sentry 14's async TelemetryProcessor, so a fixed sleep would
    # only guess at delivery and could exit before the buffer flushes.
    case Sentry.capture_message(
           "engram.sentry.smoke: pipeline test",
           level: :error,
           tags: %{smoke_marker: "engram.sentry.smoke"},
           result: :sync
         ) do
      {:ok, event_id} ->
        Mix.shell().info(
          "Sentry smoke event #{event_id} accepted. Check the project for tag " <>
            "smoke_marker=engram.sentry.smoke."
        )

      other ->
        Mix.raise("Sentry smoke event was not sent: #{inspect(other)}")
    end
  end
end
