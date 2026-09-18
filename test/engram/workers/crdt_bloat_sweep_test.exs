defmodule Engram.Workers.CrdtBloatSweepTest do
  @moduledoc """
  The sweep's whole premise is that column lengths alone recover plaintext sizes
  (#1706): AES-GCM ciphertext is plaintext-length plus a fixed tag, so no DEK is
  needed to size the database. If that arithmetic is wrong the gauges are wrong
  by a constant per row and nothing else notices — the numbers stay plausible.
  So these tests assert the byte totals EXACTLY against known inputs rather than
  checking they are merely non-zero.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Workers.CrdtBloatSweep

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "CrdtBloatSweepTest", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp seeded_note(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})

    # upsert_note alone may leave crdt_state unset; a checkpoint is what writes
    # the column this sweep measures.
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), content)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    note
  end

  defp attach do
    test_pid = self()
    id = "bloat-sweep-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:engram, :crdt, :state_sweep],
      fn _e, meas, meta, _ -> send(test_pid, {:sweep, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "sizes every stored note from column lengths alone", ctx do
    %{user: user, vault: vault} = ctx

    a = "alpha content here"
    b = String.duplicate("beta ", 40)

    seeded_note(user, vault, "a.md", a)
    seeded_note(user, vault, "b.md", b)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})

    assert_receive {:sweep, m, meta}
    assert meta == %{}

    assert m.notes == 2

    # The load-bearing assertion. Off-by-the-tag would still look reasonable.
    assert m.content_bytes_total == byte_size(a) + byte_size(b)

    assert m.state_bytes_total > 0
    assert m.bloat_ratio_p50 > 0
    assert m.bloat_ratio_max >= m.bloat_ratio_p99
    assert m.bloat_ratio_p99 >= m.bloat_ratio_p50
    assert is_integer(m.notes_over_threshold)
  end

  test "an empty database reports zeroes rather than raising", ctx do
    %{user: _user} = ctx

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})

    assert_receive {:sweep, m, _meta}
    assert m.notes == 0
    assert m.bloat_ratio_p50 == 0.0
    assert m.bloat_ratio_max == 0.0
    assert m.state_bytes_total == 0
    assert m.notes_over_threshold == 0
  end

  test "soft-deleted notes are excluded", ctx do
    %{user: user, vault: vault} = ctx

    kept = "kept content"
    seeded_note(user, vault, "kept.md", kept)
    gone = seeded_note(user, vault, "gone.md", "tombstoned content")

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^gone.id),
          set: [deleted_at: DateTime.utc_now()]
        )
      end)

    attach()

    assert :ok = perform_job(CrdtBloatSweep, %{})

    assert_receive {:sweep, m, _meta}
    assert m.notes == 1
    assert m.content_bytes_total == byte_size(kept)
  end
end
