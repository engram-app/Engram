defmodule Engram.ConversationMeter do
  @moduledoc """
  Pricing v2 §D — conversation-meter gaming defense.

  Counts MCP queries the same way users intuit "one conversation": a sliding
  30-minute window of activity. Inside one conversation, queries are capped
  (50 on Free) so 500-query batches inside a window can't bypass the
  "5 conversations/day" Free cap.

  Each `tick/1` either:

    - advances the active conversation's query count (still within window
      AND under per-conversation cap), or
    - force-rotates to a new conversation (cap hit OR window expired),
      incrementing `conversations_today`, OR
    - rejects with `{:rate_limited, reason}` when the day cap is hit or the
      per-day query cap is hit.

  Concurrent calls from multiple MCP clients are serialized with a Postgres
  advisory lock keyed off `user_id`, so two clients can't both think they
  started "the same" new conversation.
  """

  import Ecto.Query
  alias Engram.Accounts
  alias Engram.Billing
  alias Engram.Repo
  alias Engram.UsageMeters.Meter

  @advisory_lock_key 2_739_201

  @spec tick(integer()) ::
          :ok
          | {:rate_limited, :conversations_per_day | :queries_per_day | :queries_per_conversation}
  def tick(user_id) when is_binary(user_id) do
    user = Accounts.get_user!(user_id)

    Repo.transaction(
      fn ->
        # `pg_advisory_xact_lock(int4, int4)` requires int args; hash the uuid
        # user_id into a stable int32 (collision risk is latency-only, identical
        # to the attachments per-path lock pattern in attachments.ex).
        _ =
          Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1, $2)", [
            @advisory_lock_key,
            :erlang.phash2(user_id, 2_147_483_647)
          ])

        do_tick(user, ensure_row(user_id))
      end,
      skip_tenant_check: true
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:rate_limited, reason}
    end
  end

  defp ensure_row(user_id) do
    case Repo.one(from(m in Meter, where: m.user_id == ^user_id), skip_tenant_check: true) do
      %Meter{} = meter ->
        meter

      nil ->
        %Meter{user_id: user_id, updated_at: DateTime.utc_now()}
        |> Repo.insert!(skip_tenant_check: true, on_conflict: :nothing)

        Repo.one!(from(m in Meter, where: m.user_id == ^user_id), skip_tenant_check: true)
    end
  end

  defp do_tick(user, meter) do
    today = Date.utc_today()
    now = DateTime.utc_now()

    meter = rollover_day(meter, today)

    {meter, rotated?} = maybe_rotate_conversation(user, meter, now)

    cond do
      day_cap_exceeded?(user, meter) ->
        :telemetry.execute(
          [:engram, :abuse, :conversation_blocked],
          %{count: 1},
          %{user_id: user.id, reason: :conversations_per_day}
        )

        {:rate_limited, :conversations_per_day}

      query_day_cap_exceeded?(user, meter) ->
        :telemetry.execute(
          [:engram, :abuse, :conversation_blocked],
          %{count: 1},
          %{user_id: user.id, reason: :queries_per_day}
        )

        {:rate_limited, :queries_per_day}

      true ->
        meter
        |> Ecto.Changeset.change(%{
          active_conversation_query_count: meter.active_conversation_query_count + 1,
          queries_today: meter.queries_today + 1,
          updated_at: now
        })
        |> Repo.update!(skip_tenant_check: true)

        _ = rotated?
        :ok
    end
  end

  defp rollover_day(%Meter{} = meter, today) do
    if meter.conversations_day_key == today and meter.queries_day_key == today do
      meter
    else
      # Day flipped — counters reset AND the active conversation closes so
      # the next tick starts fresh on the new day (counts as conversation #1).
      meter
      |> Ecto.Changeset.change(%{
        conversations_today: 0,
        conversations_day_key: today,
        queries_today: 0,
        queries_day_key: today,
        active_conversation_started_at: nil,
        active_conversation_query_count: 0
      })
      |> Repo.update!(skip_tenant_check: true)
    end
  end

  defp maybe_rotate_conversation(user, %Meter{} = meter, now) do
    window_minutes =
      Billing.effective_limit(user, :conversation_window_minutes) |> normalize_int(30)

    per_conv_cap = Billing.effective_limit(user, :ai_queries_per_conversation)

    expired_window? =
      case meter.active_conversation_started_at do
        nil -> true
        ts -> DateTime.diff(now, ts, :second) > window_minutes * 60
      end

    over_per_conv_cap? =
      case per_conv_cap do
        :unlimited -> false
        nil -> false
        cap when is_integer(cap) -> meter.active_conversation_query_count >= cap
        _ -> false
      end

    if expired_window? or over_per_conv_cap? do
      meter =
        meter
        |> Ecto.Changeset.change(%{
          active_conversation_started_at: now,
          active_conversation_query_count: 0,
          conversations_today: meter.conversations_today + 1
        })
        |> Repo.update!(skip_tenant_check: true)

      :telemetry.execute(
        [:engram, :abuse, :conversation_rotated],
        %{count: 1},
        %{user_id: user.id, reason: rotate_reason(expired_window?, over_per_conv_cap?)}
      )

      {meter, true}
    else
      {meter, false}
    end
  end

  defp rotate_reason(true, _), do: :window_expired
  defp rotate_reason(_, true), do: :per_conv_cap

  defp day_cap_exceeded?(user, %Meter{conversations_today: today}) do
    case Billing.effective_limit(user, :ai_conversations_per_day) do
      :unlimited -> false
      nil -> false
      cap when is_integer(cap) -> today > cap
      _ -> false
    end
  end

  defp query_day_cap_exceeded?(user, %Meter{queries_today: today}) do
    case Billing.effective_limit(user, :ai_queries_per_day) do
      :unlimited -> false
      nil -> false
      cap when is_integer(cap) -> today >= cap
      _ -> false
    end
  end

  defp normalize_int(:unlimited, default), do: default
  defp normalize_int(nil, default), do: default
  defp normalize_int(n, _) when is_integer(n), do: n
  defp normalize_int(_, default), do: default
end
