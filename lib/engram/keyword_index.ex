defmodule Engram.KeywordIndex do
  @moduledoc """
  Behaviour for the keyword (full-text) leg of hybrid search (#595).

  This is the swap seam. Today the only impl is `Engram.KeywordIndex.Postgres`
  (native `tsvector` + `ts_rank_cd` on the primary RDS). When keyword relevance
  becomes a measured bottleneck at scale, a `KeywordIndex.TigerCloud`
  (`pg_textsearch` BM25) adapter drops in behind the same callbacks — call
  sites in `Engram.Search` and `Engram.Workers.EmbedNote` never change. See the
  decision log on issue #595.

  Resolve the configured impl with `module/0`.
  """

  @typedoc "Plaintext-populated note (persisted row + decrypted `content`/`title`)."
  @type note :: Engram.Notes.Note.t()

  @typedoc "Tenant + vault scope for a search. `vault_id: nil` searches all of the user's vaults."
  @type scope :: %{required(:user_id) => String.t(), optional(:vault_id) => String.t() | nil}

  @typedoc "A ranked hit: the note id and its keyword relevance score (higher = better)."
  @type hit :: {note_id :: String.t(), rank :: float()}

  @doc "Index (insert-or-replace) a note's plaintext into the keyword store."
  @callback upsert(note()) :: :ok | {:error, term()}

  @doc "Remove a note from the keyword store."
  @callback delete(note_id :: String.t()) :: :ok

  @doc """
  Return up to `:limit` keyword hits for `query` within `scope`, best-ranked
  first. Must isolate by tenant.
  """
  @callback search(query :: String.t(), scope(), opts :: keyword()) :: {:ok, [hit()]}

  @doc "The configured keyword-index adapter (defaults to the native Postgres leg)."
  @spec module() :: module()
  def module, do: Application.get_env(:engram, :keyword_index, Engram.KeywordIndex.Postgres)
end
