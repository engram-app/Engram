defmodule EngramWeb.StorageController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Attachments
  alias Engram.Billing

  # Self-host (limits not enforced) sees Pro's per-file cap as the displayed
  # ceiling — operators get an unsurprising number, and the actual gate is
  # unbounded (Billing.effective_limit returns :unlimited).
  @selfhost_max_file_bytes 524_288_000
  @max_storage_bytes 1_073_741_824

  operation(:index,
    summary: "Get storage usage and caps",
    tags: ["Account"],
    responses: [ok: {"Storage usage", "application/json", Schemas.StorageUsage}]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    {:ok, usage} = Attachments.storage_usage(user)

    json(conn, %{
      used_bytes: usage.used_bytes,
      file_count: usage.file_count,
      max_bytes: @max_storage_bytes,
      max_attachment_bytes: max_attachment_bytes(user)
    })
  end

  defp max_attachment_bytes(user) do
    case Billing.effective_limit(user, :max_file_bytes) do
      n when is_integer(n) -> n
      _ -> @selfhost_max_file_bytes
    end
  end
end
