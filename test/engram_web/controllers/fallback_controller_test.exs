defmodule EngramWeb.FallbackControllerTest do
  @moduledoc """
  Wire-parity net for the shared action_fallback clauses: every clause's
  status + JSON body is pinned byte-for-byte to the hand-rolled shape it
  replaced. If one of these fails, a converted controller path changed its
  response on the wire.
  """
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.FallbackController

  defp render(tuple) do
    FallbackController.call(build_conn(), tuple)
  end

  test "{:error, %Ecto.Changeset{}} -> 422 %{errors: format_errors(cs)}" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required([:name])

    conn = render({:error, changeset})
    assert json_response(conn, 422) == %{"errors" => %{"name" => ["can't be blank"]}}
  end

  test "{:error, :not_found} -> 404 %{error: not_found}" do
    conn = render({:error, :not_found})
    assert json_response(conn, 404) == %{"error" => "not_found"}
  end

  test "{:error, {:not_found, id}} -> 404 with item_id" do
    conn = render({:error, {:not_found, "abc-123"}})
    assert json_response(conn, 404) == %{"error" => "not_found", "item_id" => "abc-123"}
  end

  test "{:error, :conflict} -> 409 %{error: conflict}" do
    conn = render({:error, :conflict})
    assert json_response(conn, 409) == %{"error" => "conflict"}
  end

  test "{:error, {:conflict, id}} -> 409 with item_id" do
    conn = render({:error, {:conflict, "abc-123"}})
    assert json_response(conn, 409) == %{"error" => "conflict", "item_id" => "abc-123"}
  end

  test "{:error, :last_admin} -> 409 %{error: last_admin}" do
    conn = render({:error, :last_admin})
    assert json_response(conn, 409) == %{"error" => "last_admin"}
  end

  test "terminal {:error, _} -> 500 %{error: internal}" do
    conn = render({:error, :some_unexpected_reason})
    assert json_response(conn, 500) == %{"error" => "internal"}
  end
end
