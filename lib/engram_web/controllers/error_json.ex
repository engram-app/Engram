defmodule EngramWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  # Same body as RotationLockCheck's halt, for a write refused in its own
  # tenant transaction (Engram.Crypto.RotationGate.gated/1).
  def render("503.json", %{reason: %Engram.Crypto.RotationInProgress{}}),
    do: %{error: "rotation_in_progress"}

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
