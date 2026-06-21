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
      query_model: as_model(Billing.effective_limit(user, :search_query_model)),
      full_precision: as_bool(Billing.effective_limit(user, :search_full_precision)),
      reranker: as_bool(Billing.effective_limit(user, :reranker_enabled)),
      diversity: as_int(Billing.effective_limit(user, :search_diversity), 0) / 100.0,
      candidate_pool: as_int(Billing.effective_limit(user, :search_candidate_pool), @default_pool)
    }
  end

  # value coercers (operate on the already-resolved value, NOT the key)

  # `:unlimited` means limits are disabled (self-host) — grant quality features.
  defp as_bool(true), do: true
  defp as_bool(:unlimited), do: true
  defp as_bool(_), do: false

  defp as_int(n, _fallback) when is_integer(n), do: n
  defp as_int(_, fallback), do: fallback

  defp as_model(m) when is_binary(m), do: m
  defp as_model(_), do: nil
end
