defmodule Engram.Email.Provider do
  @moduledoc """
  Behaviour over transactional email send. Live impl is `Engram.Email.Resend`;
  tests use a Mox; self-host without `RESEND_API_KEY` falls back to
  `Engram.Email.NoOp` which logs + drops.
  """

  @callback send(
              to :: String.t(),
              subject :: String.t(),
              html :: String.t(),
              opts :: keyword()
            ) :: :ok | {:error, term()}
end
