defmodule EngramWeb.CrdtSyncController do
  @moduledoc """
  REST transport for Yjs updates (single-authority sync, Phase 1). Thin wrapper
  over `Engram.Notes.CrdtTransport`; auth + vault scoping come from the pipeline.
  """
  use EngramWeb, :controller

  alias Engram.Notes.CrdtTransport

  # POST /api/notes/:id/updates   body: {"update": "<base64 v1 update>"}
  def post_update(conn, %{"id" => id, "update" => b64}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, note_id} <- cast_uuid(id),
         {:ok, update} <- decode_std(b64),
         {:ok, %{head: head}} <- CrdtTransport.apply_update(user, vault, note_id, update) do
      json(conn, %{head: head})
    else
      {:error, :bad_uuid} -> error(conn, 400, "invalid note id")
      {:error, :bad_base64} -> error(conn, 400, "invalid base64 update")
      {:error, :not_found} -> error(conn, 404, "note not found")
      {:error, :invalid_update} -> error(conn, 422, "update failed to apply")
      {:error, :room_unavailable} -> error(conn, 503, "sync room unavailable, retry")
    end
  end

  def post_update(conn, %{"id" => _}), do: error(conn, 400, "missing update")

  # GET /api/notes/:id/updates?since=<url-safe base64 state vector>
  def get_updates(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, note_id} <- cast_uuid(id),
         {:ok, since} <- decode_since(params["since"]),
         {:ok, %{update: update, head: head}} <-
           CrdtTransport.read_delta(user, vault, note_id, since) do
      json(conn, %{update: Base.encode64(update), head: head})
    else
      {:error, :bad_uuid} -> error(conn, 400, "invalid note id")
      {:error, :bad_since} -> error(conn, 400, "invalid since vector")
      {:error, :not_found} -> error(conn, 404, "note not found")
    end
  end

  # GET /api/vault/heads
  def vault_heads(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    json(conn, %{heads: CrdtTransport.vault_heads(user, vault)})
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :bad_uuid}
    end
  end

  defp decode_std(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_base64}
    end
  end

  defp decode_std(_), do: {:error, :bad_base64}

  defp decode_since(nil), do: {:ok, nil}

  # Accept BOTH base64 alphabets. The plugin encodes `since` with standard
  # base64 (btoa -> +///), but this query-param path previously decoded only the
  # url-safe alphabet, so every non-genesis cold-receive delta pull 400'd (empty
  # "AA==" vectors have no +// and masked it). Try url-safe first (future-proof),
  # fall back to standard (what deployed clients send) so all clients converge.
  defp decode_since(sv) when is_binary(sv) do
    with :error <- Base.url_decode64(sv, padding: false),
         :error <- Base.decode64(sv, padding: false) do
      {:error, :bad_since}
    else
      {:ok, bin} -> {:ok, bin}
    end
  end

  defp decode_since(_), do: {:error, :bad_since}

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
