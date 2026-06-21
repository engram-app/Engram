defmodule Engram.Cache do
  @moduledoc """
  Cache backend selector shared by the per-user caches
  (`Engram.UsageMeters.ActivityCache`, `Engram.Onboarding.TermsCache`).

  The backend is always `:ets` — each cache owns a per-node ETS table.
  Redis/Valkey support has been removed (Task 8 — Phase 3).
  """

  @spec backend() :: :ets
  def backend, do: :ets
end
