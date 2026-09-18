defmodule Engram.OAuthVaultSelectionRlsTest do
  @moduledoc """
  Pins OAuth vault-selection against an ENFORCED row-level security policy.

  ## What breaks

  `resolve_vaults/2` verifies that every vault id in a consent-screen
  selection belongs to the user, then requires the count to match:

      case Repo.all(query, skip_tenant_check: true) do
        found when length(found) == length(wanted) -> {:ok, Enum.sort(found)}
        _ -> :error
      end

  `vaults` carries FORCE ROW LEVEL SECURITY, so unscoped that read returns
  `[]`, the length comparison fails, and every selection is rejected as
  `:error` — which `mint_authorization_code/4` turns into an `access_denied`
  redirect. A user granting an OAuth client access to a vault they own is
  refused, and the refusal names the wrong cause.

  The ownership predicate (`v.user_id == ^user.id`) is the right check and
  stays; it simply never gets the chance to be correct, because the policy
  filters first.

  Only the multi-vault branch is affected. `:all` short-circuits to
  `{:ok, nil}` without a query, which is why the existing OAuth tests — which
  almost all pass `:all` — do not catch this.

  ## Harness notes

  Nothing on this path opens a `with_tenant/2`, so no leaked tenant can mask
  it. The rolling-back harness is right: the assertion is about the RETURNED
  value, and the `oauth_authorization_codes` insert on the success path is
  incidental (that table carries no policy).
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.OAuth
  alias Engram.Repo
  alias Engram.Vaults.Vault

  setup do
    client = insert(:oauth_client)
    user = insert(:user)
    vault = insert(:vault, user: user)

    verifier = "verifier-that-is-long-enough-to-be-plausible"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    validated = %{
      client: client,
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uri: hd(client.redirect_uris),
      code_challenge: challenge,
      code_challenge_method: "S256",
      scope: "mcp",
      state: nil
    }

    %{user: user, vault: vault, validated: validated}
  end

  describe "vault selection under enforced RLS" do
    # CONTROL. Without it a green file cannot distinguish "correctly scoped"
    # from "the role drop never engaged".
    test "control: the dropped role cannot see the user's vault", %{vault: vault} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(v in Vault, where: v.id == ^vault.id, select: count(v.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "a selection naming a vault the user owns is granted, not access_denied",
         %{user: user, vault: vault, validated: validated} do
      outcome =
        as_prod_role(fn ->
          OAuth.mint_authorization_code(user, validated, [vault.id], nil)
        end)

      assert {:returned, {:ok, _redirect_url}} = outcome,
             """
             the grant was refused for a vault the user owns — `resolve_vaults/2`'s
             read was filtered, so `length(found) == length(wanted)` failed and the
             consent screen returns access_denied naming the wrong cause.

               got: #{inspect(outcome)}
             """
    end
  end
end
