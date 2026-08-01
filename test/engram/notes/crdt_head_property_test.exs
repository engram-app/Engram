defmodule Engram.Notes.CrdtHeadPropertyTest do
  @moduledoc """
  Property (#285 / issue #1068): the head/text `GET /notes/:id/updates` serves
  must reflect EVERY acked write — no acked update is ever lost and the served
  head never regresses.

  ## What it drives (through PUBLIC contexts only)

  A random sequence of commands against ONE note:

    * `:edit_via_room`  — durable effect of an acked live edit: an encrypted Yjs
      delta appended as a `crdt_update_log` tail row (exactly what
      `CrdtPersistence.update_v1` persists, minus the ephemeral fan-out). Each
      edit appends a UNIQUE token to the body.
    * `:checkpoint_now` — STAGE the deferred `CheckpointNote` worker: rebuild the
      detached doc from durable state via `CheckpointNote.rebuild_detached/3`
      (its real rebuild txn). The persist (`finalize/1`) is deferred, modelling
      the worker's two-transaction gap where a concurrent write can land.
    * `:terminate_room` — `CrdtRegistry.terminate_room/1` (idempotent; rooms are
      ephemeral and rebuildable, so it is durable-lossless — the amplifier that
      opens the no-room window the detached worker runs in).
    * `:recreate_room`  — room re-open. Durable no-op: `bind/3` replays
      snapshot+tail, which is exactly what the read path reconstructs, so
      recreation alone loses nothing (Task 1 verdict).
    * `:read_updates`   — commit any staged checkpoint (the worker finishes),
      then `CrdtTransport.read_delta/4` and ASSERT.

  ## Invariant (asserted only through the public read path)

  Reconstructing the full server doc from `read_delta(.., nil)` must contain
  every acked token, and the served `head` must equal the head marker of that
  reconstructed doc. A tail row pruned-unfolded by the detached-checkpoint
  window drops its token here → the property fails (RED), reproducing #285.
  """
  use Engram.DataCase, async: false
  use ExUnitProperties

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtTransport, CrdtUpdateLog}
  alias Engram.Workers.CheckpointNote

  @commands [:edit_via_room, :checkpoint_now, :terminate_room, :recreate_room, :read_updates]

  @max_runs if System.get_env("CI"), do: 50, else: 200

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "HeadProperty"})
    %{user: user, vault: vault}
  end

  property "served head reflects every acked write across edit/checkpoint/terminate/recreate",
           %{user: user, vault: vault} do
    check all(cmds <- list_of(member_of(@commands), max_length: 12), max_runs: @max_runs) do
      # Fresh note per iteration so runs don't accumulate state.
      path = "n#{System.unique_integer([:positive])}.md"
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "base"})

      acc = %{
        user: user,
        vault: vault,
        note_id: note.id,
        expected: MapSet.new(["base"]),
        staged: nil,
        n: 0
      }

      # Always finish with a read so every generated sequence is observed.
      acc = Enum.reduce(cmds ++ [:read_updates], acc, &run/2)

      # Final settle + assert (covers sequences whose last real command left a
      # staged checkpoint that a mid-sequence read did not commit).
      _ = assert_head_reflects_all(commit_staged(acc))
    end
  end

  # ── command interpreter ────────────────────────────────────────────────────

  defp run(:edit_via_room, acc) do
    # Delimited token: "T<n>Z" is never a substring of "T<m>Z" for n != m, so a
    # `String.contains?` check cannot let a longer token mask a lost shorter one.
    token = "T#{acc.n}Z"
    :ok = append_edit(acc.user, acc.vault, acc.note_id, token)
    %{acc | expected: MapSet.put(acc.expected, token), n: acc.n + 1}
  end

  defp run(:checkpoint_now, acc) do
    # Commit any previously staged worker (its second txn runs "now"), then
    # stage a fresh rebuild whose persist is deferred to a later command.
    acc = commit_staged(acc)

    staged =
      case CheckpointNote.rebuild_detached(acc.user.id, acc.vault.id, acc.note_id) do
        {:ok, token} -> token
        :skip -> nil
      end

    %{acc | staged: staged}
  end

  defp run(:terminate_room, acc) do
    :ok = CrdtRegistry.terminate_room(acc.note_id)
    acc
  end

  defp run(:recreate_room, acc), do: acc

  defp run(:read_updates, acc) do
    acc = commit_staged(acc)
    assert_head_reflects_all(acc)
    acc
  end

  # ── staged detached checkpoint ─────────────────────────────────────────────

  defp commit_staged(%{staged: nil} = acc), do: acc

  defp commit_staged(%{staged: token} = acc) do
    :ok = CheckpointNote.finalize(token)
    %{acc | staged: nil}
  end

  # ── invariant ──────────────────────────────────────────────────────────────

  defp assert_head_reflects_all(acc) do
    {:ok, %{update: full, head: head}} =
      CrdtTransport.read_delta(acc.user, acc.vault, acc.note_id, nil)

    client = CrdtBridge.new_doc()
    :ok = Yex.apply_update(client, full)
    text = CrdtBridge.text_of(client)

    missing = Enum.reject(MapSet.to_list(acc.expected), &String.contains?(text, &1))

    assert missing == [],
           "served head/text lost acked token(s) #{inspect(missing)} — regressed head. text=#{inspect(text)}"

    # Head consistency: the served head marker is the head of the doc a client
    # reconstructs from the served full state.
    assert head == CrdtTransport.head_marker(client),
           "served head does not match the reconstructed authoritative doc"

    acc
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Durable effect of an acked live edit: encrypt the Yjs delta (a pure append of
  # " token") and append it as a tail-log row — what update_v1 persists. No room
  # process, so no sandbox-connection poisoning; deterministic.
  defp append_edit(user, vault, note_id, token) do
    {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, note_id, nil)
    doc = CrdtBridge.new_doc()
    :ok = Yex.apply_update(doc, full)
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    sv_before = Yex.encode_state_vector!(doc)
    :ok = CrdtBridge.diff_into_text(text, CrdtBridge.text_of(doc) <> " " <> token)
    {:ok, delta} = Yex.encode_state_as_update(doc, sv_before)
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(delta, user, note_id)

    Repo.with_tenant(user.id, fn ->
      %CrdtUpdateLog{}
      |> CrdtUpdateLog.changeset(%{
        note_id: note_id,
        user_id: user.id,
        vault_id: vault.id,
        update_ciphertext: ct,
        update_nonce: nonce
      })
      |> Repo.insert!()
    end)

    :ok
  end
end
