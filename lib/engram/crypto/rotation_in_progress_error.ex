defmodule Engram.Crypto.RotationInProgressError do
  @moduledoc """
  Raised by a `RotationGate.gated/1` tenant transaction whose user has a DEK
  rotation in flight. Rendered as 503 `rotation_in_progress` (EngramWeb.ErrorJSON;
  the `Retry-After` header comes from `EngramWeb.Plugs.RotationLockCheck`).
  """
  defexception message: "dek rotation in progress", plug_status: 503
end
