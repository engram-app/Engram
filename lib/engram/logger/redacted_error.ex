defmodule Engram.Logger.RedactedError do
  @moduledoc """
  Stand-in for an exception whose message may carry user data.

  Built by `Engram.Logger.SafeException.sanitize/1`. `type` keeps the original
  module so the rendered banner still says what went wrong; `message` is
  `Engram.Logger.Metadata.safe_reason/1`-derived, never `inspect(term)`.
  """
  defexception [:type, :message]
end
