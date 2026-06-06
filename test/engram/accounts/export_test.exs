defmodule Engram.Accounts.ExportTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Accounts.Export

  import Engram.Factory

  describe "request/1" do
    test "inserts pending row + enqueues worker" do
      user = insert(:user)
      {:ok, export} = Export.request(user)
      assert export.status == :pending
      assert export.user_id == user.id
      assert export.reason == :user_request

      assert [%Oban.Job{args: %{"export_id" => id}}] =
               all_enqueued(worker: Engram.Workers.AccountExport)

      assert id == export.id
    end
  end
end
