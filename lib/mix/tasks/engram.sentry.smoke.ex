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

    _ =
      Sentry.capture_message(
        "engram.sentry.smoke — pipeline test",
        level: :error,
        tags: %{smoke_marker: "engram.sentry.smoke"}
      )

    Process.sleep(1_500)

    Mix.shell().info(
      "Sentry smoke event dispatched. Check the project for tag smoke_marker=engram.sentry.smoke."
    )
  end
end
