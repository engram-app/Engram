defmodule Mix.Tasks.Engram.SetCooldown do
  @moduledoc """
  Set per-user encryption-toggle cooldown without dropping into raw SQL.

      mix engram.set_cooldown <user_id> <days|null>

  `days` accepts a non-negative integer (cooldown in days) or `null`/`none`
  to clear the column (the user can re-toggle encryption immediately).
  Used by the hosted operator until a Stripe-webhook driver is in place;
  see `docs/encryption-toggle-followups.md` Phase 3 #10.
  """

  use Mix.Task

  alias Engram.Accounts

  @shortdoc "Set encryption_toggle_cooldown_days for a user"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [user_id_str, days_str] ->
        with {:ok, user_id} <- parse_user_id(user_id_str),
             {:ok, days} <- parse_days(days_str) do
          do_set(user_id, days)
        else
          {:error, msg} ->
            Mix.shell().error(msg)
            System.halt(1)
        end

      _ ->
        Mix.shell().error("Usage: mix engram.set_cooldown <user_id> <days|null>")
        System.halt(1)
    end
  end

  defp parse_user_id(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "user_id must be a positive integer (got #{inspect(s)})"}
    end
  end

  defp parse_days(s) when s in ["null", "none", "NULL"], do: {:ok, nil}

  defp parse_days(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "days must be a non-negative integer or 'null' (got #{inspect(s)})"}
    end
  end

  defp do_set(user_id, days) do
    case Accounts.get_user(user_id) do
      nil ->
        Mix.shell().error("No user with id=#{user_id}")
        System.halt(1)

      user ->
        case Accounts.set_encryption_toggle_cooldown_days(user, days) do
          {:ok, _user} ->
            label = if is_nil(days), do: "NULL (no cooldown)", else: "#{days} day(s)"
            Mix.shell().info("Set user #{user_id} cooldown to #{label}")

          {:error, changeset} ->
            Mix.shell().error("Update failed: #{inspect(changeset.errors)}")
            System.halt(1)
        end
    end
  end
end
