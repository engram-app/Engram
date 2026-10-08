defmodule Engram.NotesSeqFeedDecryptBudgetTest do
  @moduledoc """
  Compressed rows (format 1) are tiny at rest but huge decrypted, so the
  catch-up page budget has to be enforced on PLAINTEXT while decrypting
  (peak = budget + one row), not on the stored ciphertext size (#1872).

  async: false because the decrypt_batch telemetry handler is global: it would
  count other tests' decrypts.
  """
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.{Notes, Vaults}
  alias Engram.Notes.Note

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "T", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp drain_note_decrypts(ref, acc) do
    receive do
      {[:engram, :crypto, :decrypt_batch], ^ref, %{count: c}, %{kind: :notes}} ->
        drain_note_decrypts(ref, acc + c)
    after
      0 -> acc
    end
  end

  test "decrypt stops at the plaintext budget; later rows are not decrypted", ctx do
    %{user: user, vault: vault} = ctx
    two_mb = String.duplicate("repeated line of text\n", div(2 * 1024 * 1024, 22) + 1)

    for i <- 1..5 do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "z#{i}.md", "content" => two_mb}, actor: "api")
    end

    {:ok, stored} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.all(
          from(n in Note, select: fragment("octet_length(?)", n.content_ciphertext))
        )
      end)

    assert Enum.all?(stored, &(&1 < 100_000)), "fixture must be stored tiny: #{inspect(stored)}"

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :decrypt_batch]])

    {:ok, %{changes: page, has_more: more, next: next}} =
      Notes.list_changes_by_seq(user, vault, 0, limit: 500, max_bytes: 3 * 1024 * 1024)

    assert length(page) == 1
    assert more and next

    # The shipped row plus the one that overflowed; rows 3..5 never decrypted.
    assert drain_note_decrypts(ref, 0) <= 2

    # Nothing lost: resuming from the cursor yields the other four.
    {last_seq, last_id} = next

    {:ok, %{changes: rest}} =
      Notes.list_changes_by_seq(user, vault, last_seq,
        limit: 500,
        after_id: last_id,
        max_bytes: 100 * 1024 * 1024
      )

    assert length(rest) == 4
  end
end
