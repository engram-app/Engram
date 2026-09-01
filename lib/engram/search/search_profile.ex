defmodule Engram.Search.SearchProfile do
  @moduledoc """
  Per-request, per-user resolution of all search-quality dials.

  Every field resolves through `Engram.Billing.effective_limit/2`, i.e. the
  4-layer chain: per-user override (DB) → env override → plan config → tier
  default. Changing any layer (e.g. an admin override row) takes effect live,
  no restart — see `Engram.Billing.OverrideCache`.
  """

  alias Engram.Billing

  @default_pool 20

  defstruct query_model: nil,
            semantic: true,
            full_precision: false,
            reranker: false,
            diversity: 0.0,
            candidate_pool: @default_pool

  @type t :: %__MODULE__{
          query_model: String.t() | nil,
          semantic: boolean(),
          full_precision: boolean(),
          reranker: boolean(),
          diversity: float(),
          candidate_pool: pos_integer()
        }

  @spec resolve(map()) :: t()
  def resolve(user) do
    %__MODULE__{
      query_model: as_model(Billing.effective_limit(user, :search_query_model)),
      semantic: Billing.granted?(user, :search_semantic_enabled),
      full_precision: Billing.granted?(user, :search_full_precision),
      reranker: Billing.granted?(user, :reranker_enabled),
      # fallback 30 = 0.3 default; self-host (no cap) gets MMR like every tier
      # `||` is safe because `Billing.cap/2` answers nil for a malformed override
      # as well as for every "no cap" spelling — these are dials, and `"30" /
      # 100.0` would raise on every search for that user.
      diversity: (Billing.cap(user, :search_diversity) || 30) / 100.0,
      candidate_pool: Billing.cap(user, :search_candidate_pool) || @default_pool
    }
  end

  # `search_query_model` is the one :string key in the catalog, so it has no
  # `Billing` decoder — every "no model" spelling collapses to nil here.
  defp as_model(m) when is_binary(m), do: m
  defp as_model(_), do: nil
end
