defmodule Engram.Notes.MaterializationCheckTest do
  @moduledoc """
  CI gate: fails if any user/vault has notes referencing folder paths
  without a matching folder_marker row. Prevents regression once HT
  migration assumes every folder has a stable id.
  """
  use Engram.DataCase, async: false

  alias Engram.{Accounts, Notes, Vaults}

  @tag :materialization_check
  test "every implied folder has a folder_marker row" do
    orphans =
      for user <- Accounts.list_users(),
          vault <- Vaults.list_vaults(user),
          orphan <- Notes.Materialization.orphans(user, vault) do
        "user=#{user.id} vault=#{vault.id} folder=#{inspect(orphan)}"
      end

    assert orphans == [],
           "Found #{length(orphans)} orphan folder paths — run mix engram.materialize_folders.\n" <>
             Enum.join(orphans, "\n")
  end
end
