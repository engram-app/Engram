defmodule Engram.SmokeContractReference do
  @moduledoc """
  FIXTURE for migration-safety-tier-1. References `:legacy_smoke_flag` to
  trip the contract-phase-references CI gate. Delete with the matching
  migration fixture before merging the branch.
  """

  def legacy_smoke_flag, do: :legacy_smoke_flag
end
