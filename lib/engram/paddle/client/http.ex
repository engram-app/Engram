defmodule Engram.Paddle.Client.HTTP do
  @moduledoc """
  Default `Engram.Paddle.Client` implementation — thin Req wrapper over the
  Paddle Billing REST API. Base URL is chosen by `:paddle_env`
  (`"sandbox"` → sandbox-api.paddle.com, anything else → api.paddle.com).
  """

  @behaviour Engram.Paddle.Client

  alias Engram.Logger.Metadata

  require Logger

  @sandbox_base "https://sandbox-api.paddle.com"
  @production_base "https://api.paddle.com"

  @impl true
  def create_customer_portal_session(customer_id) when is_binary(customer_id) do
    request(
      :post,
      "/customers/" <> customer_id <> "/portal-sessions",
      "portal-session",
      fn
        %Req.Response{
          status: 201,
          body: %{"data" => %{"urls" => %{"general" => %{"overview" => overview}}}}
        } ->
          {:ok, overview}

        _ ->
          :error
      end,
      json: %{},
      # This endpoint predates log_non_2xx and logged "non-201"; the message
      # is kept verbatim so log-based alerting/queries don't silently break.
      log_message: "Paddle portal-session non-201"
    )
  end

  @impl true
  def get_subscription(subscription_id) when is_binary(subscription_id) do
    request(:get, "/subscriptions/" <> subscription_id, "subscription", fn
      %Req.Response{status: 200, body: %{"data" => data}} -> {:ok, data}
      _ -> :error
    end)
  end

  @impl true
  def list_transactions(subscription_id) when is_binary(subscription_id) do
    request(
      :get,
      "/transactions",
      "transactions",
      fn
        %Req.Response{status: 200, body: %{"data" => data}} when is_list(data) -> {:ok, data}
        _ -> :error
      end,
      params: [subscription_id: subscription_id, order_by: "billed_at[DESC]", per_page: 50]
    )
  end

  @impl true
  def get_transaction_invoice(transaction_id) when is_binary(transaction_id) do
    request(:get, "/transactions/" <> transaction_id <> "/invoice", "transaction-invoice", fn
      %Req.Response{status: 200, body: %{"data" => %{"url" => invoice_url}}} -> {:ok, invoice_url}
      _ -> :error
    end)
  end

  @impl true
  def get_portal_session(customer_id) when is_binary(customer_id) do
    request(
      :post,
      "/customers/" <> customer_id <> "/portal-sessions",
      "portal-session",
      fn
        %Req.Response{status: 201, body: %{"data" => %{"urls" => urls}}} -> {:ok, urls}
        _ -> :error
      end,
      json: %{}
    )
  end

  @impl true
  def list_subscriptions(%DateTime{} = since) do
    with {:ok, api_key} <- fetch_api_key() do
      iso = DateTime.to_iso8601(since)
      url = base_url() <> "/subscriptions"
      params = [{"updated_at[GTE]", iso}, {"per_page", 200}]
      list_pages(url, params, headers(api_key), [], MapSet.new([url]), 1)
    end
  end

  # Hard cap on pagination to bound the daily Oban worker even if Paddle
  # misbehaves. At per_page=200 this allows 10k subscriptions per
  # reconciliation window — comfortably past current scale and easy to
  # bump if we ever approach it.
  @max_pages 50

  defp list_pages(_url, _params, _headers, acc, _seen, page) when page > @max_pages do
    Logger.error(
      "Paddle subscriptions-list page cap exceeded",
      Metadata.with_category(:error, :billing, reason_label: :max_pages_exceeded)
    )

    {:partial, Enum.reverse(acc) |> List.flatten(), :max_pages_exceeded}
  end

  defp list_pages(url, params, headers, acc, seen, page) do
    case Req.get(url, params: params, headers: headers, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data} = body}} when is_list(data) ->
        # `has_more` is Paddle's authoritative terminator: per the docs, the
        # `next` URL is ALWAYS returned (even on the last page), so stopping
        # on `next == nil` never triggers in production and walks the worker
        # past the final page until the loop/cap guard trips. Stop here unless
        # Paddle says there's another page. `next` nil/"" is kept as a belt-
        # and-suspenders terminator for older/edge responses.
        next_url = get_in(body, ["meta", "pagination", "next"])
        has_more = get_in(body, ["meta", "pagination", "has_more"])

        cond do
          has_more != true ->
            {:ok, Enum.reverse([data | acc]) |> List.flatten()}

          not is_binary(next_url) or next_url == "" ->
            {:ok, Enum.reverse([data | acc]) |> List.flatten()}

          true ->
            if MapSet.member?(seen, next_url) do
              # Paddle returned a `next` URL we've already fetched — would
              # be an infinite loop. Stop and surface what we have, tagged
              # so the caller treats it as drift signal, not a clean read.
              Logger.error(
                "Paddle subscriptions-list pagination loop detected",
                Metadata.with_category(:error, :billing, reason_label: :pagination_loop)
              )

              {:partial, Enum.reverse([data | acc]) |> List.flatten(), :pagination_loop}
            else
              # Paddle's `next` is a fully-qualified URL with all query params
              # encoded — don't pass `params:` again or Req appends them.
              list_pages(
                next_url,
                [],
                headers,
                [data | acc],
                MapSet.put(seen, next_url),
                page + 1
              )
            end
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        log_non_2xx("subscriptions-list", status, body)
        {:error, {:paddle_error, status, body}}

      {:error, reason} ->
        Logger.warning(
          "Paddle subscriptions-list transport error",
          Metadata.with_category(:warning, :billing,
            reason: inspect(reason),
            reason_label: :transport
          )
        )

        {:error, reason}
    end
  end

  @impl true
  def get_update_payment_transaction(subscription_id) when is_binary(subscription_id) do
    request(
      :get,
      "/subscriptions/" <> subscription_id <> "/update-payment-method-transaction",
      "update-payment-transaction",
      fn
        %Req.Response{status: 200, body: %{"data" => data}} -> {:ok, data}
        _ -> :error
      end
    )
  end

  @impl true
  def cancel_subscription(subscription_id, effective_from, opts \\ [])
      when is_binary(subscription_id) and effective_from in [:immediately, :next_billing_period] do
    request(
      :post,
      "/subscriptions/" <> subscription_id <> "/cancel",
      "subscription-cancel",
      fn
        %Req.Response{status: 200, body: %{"data" => data}} -> {:ok, data}
        _ -> :error
      end,
      json: %{effective_from: Atom.to_string(effective_from)},
      idempotency_key: Keyword.get(opts, :idempotency_key)
    )
  end

  @impl true
  def preview_subscription_update(subscription_id, items, opts \\ [])
      when is_binary(subscription_id) and is_list(items) do
    request(
      :patch,
      "/subscriptions/" <> subscription_id <> "/preview",
      "subscription-preview",
      fn
        %Req.Response{status: 200, body: %{"data" => data}} -> {:ok, data}
        _ -> :error
      end,
      json: subscription_update_body(items, opts)
    )
  end

  @impl true
  def update_subscription(subscription_id, items, opts \\ [])
      when is_binary(subscription_id) and is_list(items) do
    request(
      :patch,
      "/subscriptions/" <> subscription_id,
      "subscription-update",
      fn
        %Req.Response{status: 200, body: %{"data" => data}} -> {:ok, data}
        _ -> :error
      end,
      json: subscription_update_body(items, opts),
      idempotency_key: Keyword.get(opts, :idempotency_key)
    )
  end

  # ── shared request driver ─────────────────────────────────────────
  #
  # Every non-paginated Paddle call is the same shape: fetch the API key,
  # build URL + headers, issue one Req call, pattern-match the single success
  # shape, and map everything else to a warning log +
  # `{:error, {:paddle_error, status, body}}`. `extract` matches ONLY the
  # success response (status AND body shape) and returns `{:ok, result}`;
  # any other response — wrong status, or a 2xx with an unexpected body —
  # returns `:error` and takes the same non-2xx path the hand-rolled
  # versions did. (`list_subscriptions/1` stays hand-rolled: pagination.)
  #
  # Options: `:json` (request body), `:params` (query params),
  # `:idempotency_key` (adds the `paddle-ik` header when a binary),
  # `:log_message` (verbatim warning-message override — see
  # create_customer_portal_session/1).
  defp request(verb, path, label, extract, opts \\ []) do
    with {:ok, api_key} <- fetch_api_key() do
      url = base_url() <> path

      req_headers =
        case Keyword.get(opts, :idempotency_key) do
          key when is_binary(key) -> headers(api_key) ++ [{"paddle-ik", key}]
          _ -> headers(api_key)
        end

      req_opts =
        [headers: req_headers, receive_timeout: 10_000] ++
          Keyword.take(opts, [:json, :params])

      case do_req(verb, url, req_opts) do
        {:ok, %Req.Response{status: status, body: body} = resp} ->
          case extract.(resp) do
            {:ok, _} = ok ->
              ok

            :error ->
              case Keyword.get(opts, :log_message) do
                nil -> log_non_2xx(label, status, body)
                message -> log_paddle_warning(message, status, body)
              end

              {:error, {:paddle_error, status, body}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_req(:get, url, opts), do: Req.get(url, opts)
  defp do_req(:post, url, opts), do: Req.post(url, opts)
  defp do_req(:patch, url, opts), do: Req.patch(url, opts)

  # Paddle PATCH /subscriptions/{id} treats `items` as REPLACE (not merge), so
  # an empty list either 422s ('items must be non-empty') or wipes the
  # subscription. Omit the key entirely when the caller passes [] — the only
  # path that does is reverse_cancel/1, which only needs to clear
  # scheduled_change without altering items.
  defp subscription_update_body(items, opts) do
    base =
      case items do
        [] -> %{}
        list when is_list(list) -> %{items: list}
      end

    base =
      case Keyword.get(opts, :proration_billing_mode) do
        mode when is_binary(mode) -> Map.put(base, :proration_billing_mode, mode)
        _ -> base
      end

    case Keyword.get(opts, :scheduled_change, :unset) do
      :unset -> base
      value -> Map.put(base, :scheduled_change, value)
    end
  end

  defp log_non_2xx(label, status, body),
    do: log_paddle_warning("Paddle #{label} non-2xx", status, body)

  defp log_paddle_warning(message, status, body) do
    Logger.warning(
      message,
      Metadata.with_category(:warning, :billing, status: status, reason_label: inspect(body))
    )
  end

  defp fetch_api_key do
    case Application.get_env(:engram, :paddle_api_key) do
      nil -> {:error, :paddle_not_configured}
      "" -> {:error, :paddle_not_configured}
      key when is_binary(key) -> {:ok, key}
    end
  end

  defp base_url do
    case Application.get_env(:engram, :paddle_api_base_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        case Application.get_env(:engram, :paddle_env, "sandbox") do
          "production" -> @production_base
          _ -> @sandbox_base
        end
    end
  end

  defp headers(api_key) do
    [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]
  end
end
