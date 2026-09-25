defmodule AuthService.ModerationAuditContextTest do
  @moduledoc """
  `audit_logs.ip_address` and `user_agent` have existed since migration 010 and were NULL on every
  row ever written: the insert never named them. An audit row that cannot say where an action came
  from answers half the question it exists for.

  The gateway now merges `ApiGatewayWeb.RequestContext.audit_attrs/1` into every admin mutation's
  attrs, and the writer persists them. These tests pin the writer end of that contract.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Moderation

  @tenant "00000000-0000-0000-0000-000000000001"
  @ip "203.0.113.77"
  @ua "Mozilla/5.0 (Macintosh) AdminConsole/1"

  defp user!(role \\ "user") do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, role) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', $4)",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}", role]
    )

    id
  end

  defp last_audit(action) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT actor_user_id::text, ip_address, user_agent FROM audit_logs " <>
          "WHERE action = $1 ORDER BY created_at DESC, id DESC LIMIT 1",
        [action]
      )

    case rows do
      [[actor, ip, ua]] -> %{actor: actor, ip: ip, user_agent: ua}
      [] -> nil
    end
  end

  @tag :postgres_integration
  test "a ban records the actor AND where the request came from" do
    admin = user!("admin")
    target = user!()

    assert {:ok, _} =
             Moderation.ban_user(%{
               "user_id" => target,
               "app_id" => @tenant,
               "actor_user_id" => admin,
               "reason" => "spam",
               # exactly what RequestContext.audit_attrs/1 merges in
               "ip_address" => @ip,
               "user_agent" => @ua
             })

    row = last_audit("user.ban")
    assert row.actor == admin
    assert row.ip == @ip
    assert row.user_agent == @ua
  end

  @tag :postgres_integration
  test "the public write_audit carries it too — the gateway's cross-service path" do
    admin = user!("admin")

    assert {:ok, %{written: true}} =
             Moderation.write_audit(%{
               "actor_user_id" => admin,
               "action" => "user.view",
               "target_type" => "user",
               "target_id" => Ecto.UUID.generate(),
               "metadata" => %{},
               "ip_address" => @ip,
               "user_agent" => @ua
             })

    row = last_audit("user.view")
    assert row.ip == @ip
    assert row.user_agent == @ua
  end

  @tag :postgres_integration
  test "an internal caller with no request context writes NULL, not a fabricated address" do
    # Honest absence beats a proxy address that would read as evidence.
    admin = user!("admin")
    target = user!()

    assert {:ok, _} =
             Moderation.reactivate_user(%{
               "user_id" => target,
               "app_id" => @tenant,
               "actor_user_id" => admin
             })

    row = last_audit("user.reactivate")
    assert is_nil(row.ip)
    assert is_nil(row.user_agent)
  end
end
