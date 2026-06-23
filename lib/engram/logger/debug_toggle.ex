defmodule Engram.Logger.DebugToggle do
  @moduledoc """
  Operator affordance: temporarily raise one module's log verbosity to `:debug`
  at runtime, then reset. Invoke via release rpc (no HTTP surface), e.g.

      bin/engram rpc 'Engram.Logger.DebugToggle.enable(Engram.Search)'
      bin/engram rpc 'Engram.Logger.DebugToggle.reset(Engram.Search)'

  Useful for "depth on demand" debugging: flip a subsystem to debug while
  chasing a live issue, then flip it back. Module levels reset on node
  restart regardless. The enable/reset events themselves are logged
  (category `:boot`) so the change is auditable.
  """
  require Logger

  @spec enable(module()) :: :ok | {:error, term()}
  def enable(module) when is_atom(module) do
    Logger.warning(
      "debug logging enabled at runtime",
      Engram.Logger.Metadata.with_category(:warning, :boot, module: module)
    )

    :logger.set_module_level(module, :debug)
  end

  @spec reset(module()) :: :ok
  def reset(module) when is_atom(module) do
    :logger.unset_module_level(module)

    Logger.warning(
      "debug logging reset",
      Engram.Logger.Metadata.with_category(:warning, :boot, module: module)
    )

    :ok
  end
end
