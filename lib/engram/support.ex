defmodule Engram.Support do
  @moduledoc "User-submitted issue reports."
  alias Engram.Repo
  alias Engram.Support.IssueReport

  @doc """
  Insert an issue report. `user` supplies the trusted `user_id`; `attrs` are the
  client-supplied `"description"`, `"surface"`, `"app_version"`; `meta` carries
  server-derived `:vault_id` and `:device_fingerprint`.
  """
  def create_report(user, attrs, meta) do
    params = %{
      "user_id" => user.id,
      "vault_id" => meta[:vault_id],
      "device_fingerprint" => meta[:device_fingerprint],
      "surface" => attrs["surface"],
      "app_version" => attrs["app_version"],
      "description" => attrs["description"]
    }

    %IssueReport{}
    |> IssueReport.changeset(params)
    |> Repo.insert()
  end
end
