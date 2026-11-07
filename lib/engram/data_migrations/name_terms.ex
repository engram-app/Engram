defmodule Engram.DataMigrations.NameTerms do
  @moduledoc """
  Backfill of `name_terms` (O(1) folder rename plan, S1;
  `Engram.Search.NameTerms`): every live note and folder whose terms were
  not written for its current name (the `notes_name_terms_stale` /
  `folders_name_terms_stale` predicate: never written, written under an
  older stamp version, renamed or rotated since). Each pass walks `notes`
  then `folders` in id windows (`Engram.Backfill.IdWindows.heal_pass/4`),
  decrypting each stale ref's name once, at most `@max_fixed` refs per table
  per pass. Done when both walks find nothing; the search leg turns on then.

  Self-heal after done: a previous-release writer (rolling deploy, rollback)
  leaves its renames' stamps behind their hmac, and `Engram.Bookkeeping.Drain`
  finds those users through the same partial indexes and runs
  `run_pass(user_ids: ...)`. Zero operator steps; not re-verified.

  Kill switch `enabled?/0` = service override `name_terms_backfill`, default
  on. Off holds the ledger open, so the search leg stays off too.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.Folders.Folder
  alias Engram.Notes.Note
  alias Engram.Search.NameTerms

  @max_fixed 20_000

  @impl true
  def name, do: "name_terms"

  @impl true
  def version, do: NameTerms.version()

  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:name_terms_backfill, true) == true

  @doc "True once every live note and folder has current terms."
  def done?, do: Engram.DataMigrations.done?(name(), version())

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `user_ids:` heals only those users (the drain); `batch:` / `max_fixed:`
  # for tests.
  def run_pass(opts) do
    walks =
      for schema <- [Note, Folder] do
        case Keyword.fetch(opts, :user_ids) do
          {:ok, user_ids} -> heal_users(schema, user_ids, opts)
          :error -> heal_fleet(schema, opts)
        end
      end

    if Enum.all?(walks, &(&1 == :done)),
      do: :done,
      else: {:more, rows: walks |> Enum.map(&rows/1) |> Enum.sum()}
  end

  defp heal_fleet(schema, opts) do
    IdWindows.heal_pass("name_terms:#{schema.__schema__(:source)}", schema, &heal(schema, &1, &2),
      batch_size: Keyword.get(opts, :batch, 200),
      max_fixed: Keyword.get(opts, :max_fixed, @max_fixed)
    )
  end

  # The drain's users: each user's stale refs straight off the stale index
  # (O(drift), at most `NameTerms.heal_user/2`'s page per user per pass).
  defp heal_users(schema, user_ids, _opts) do
    fixed = user_ids |> Enum.map(&NameTerms.heal_user(schema, &1)) |> Enum.sum()
    if fixed == 0, do: :done, else: {:more, rows: fixed}
  end

  defp heal(schema, ids, ctx), do: NameTerms.heal_window(schema, ids, ctx)

  defp rows(:done), do: 0
  defp rows({:more, kw}), do: Keyword.get(kw, :rows, 0)
end
