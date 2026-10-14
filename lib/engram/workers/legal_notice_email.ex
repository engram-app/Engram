defmodule Engram.Workers.LegalNoticeEmail do
  @moduledoc """
  Emails one user about one legal change (`kind` "notice" or "reminder").
  Enqueued only by `Engram.Workers.LegalNoticeDispatch`.

  Skips a deleted user and one who already accepted the version (someone who
  signed up after it was published). A suppressed address is a final skip; a
  provider failure is returned so Oban retries. Legal notices are transactional,
  so analytics opt-out does not apply.
  """
  # Unique across completed jobs too: one user never gets the same notice twice.
  use Oban.Worker,
    queue: :events,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:user_id, :document, :version, :kind],
      states: [:available, :scheduled, :executing, :retryable, :completed]
    ]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Legal
  alias Engram.Legal.TermsVersion
  alias Engram.Mailer
  alias Engram.Onboarding

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => id, "document" => doc, "version" => v, "kind" => kind}
      }) do
    with %User{deleted_at: nil, email: email} = user when is_binary(email) <-
           Accounts.get_user(id),
         false <- Onboarding.accepted?(user, doc, v),
         %TermsVersion{} = version <- Legal.get(doc, v) do
      case Mailer.send_legal_notice(user, version, kind) do
        {:error, :suppressed} -> :ok
        {:error, reason} -> {:error, reason}
        _sent -> :ok
      end
    else
      _ -> :ok
    end
  end
end
