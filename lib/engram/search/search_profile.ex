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
            full_precision: false,
            reranker: false,
            diversity: 0.0,
            candidate_pool: @default_pool

  @type t :: %__MODULE__{
          query_model: String.t() | nil,
          full_precision: boolean(),
          reranker: boolean(),
          diversity: float(),
          candidate_pool: pos_integer()
        }

  @spec resolve(map()) :: t()
  def resolve(user) do
    %__MODULE__{
      query_model: resolve_model(user, :search_query_model),
      full_precision: feature?(user, :search_full_precision),
      reranker: feature?(user, :reranker_enabled),
      diversity: resolve_int(user, :search_diversity, 0) / 100.0,
      candidate_pool: resolve_int(user, :search_candidate_pool, @default_pool)
    }
  end

  # `:unlimited` means limits are disabled (self-host) — grant quality features.
  defp feature?(user, key) do
    case Billing.effective_limit(user, key) do
      true -> true
      :unlimited -> true
      _ -> false
    end
  end

  defp resolve_int(user, key, fallback) do
    case Billing.effective_limit(user, key) do
      n when is_integer(n) -> n
      _ -> fallback
    end
  end

  defp resolve_model(user, key) do
    case Billing.effective_limit(user, key) do
      m when is_binary(m) -> m
      _ -> nil
    end
  end
end
