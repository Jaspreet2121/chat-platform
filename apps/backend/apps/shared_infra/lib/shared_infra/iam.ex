defmodule SharedInfra.IAM do
  @moduledoc """
  Identity & Access Management — the fixed role hierarchy and the role→permission mapping (Phase 1).

  Roles are permission BUNDLES defined here in code (not a DB table). One role per user, stored in
  `users_auth.role`. Hierarchy, most→least privileged: root > admin > moderator > support > user.
  `user` has NO admin-console access.

    * root      — every permission (incl. content.read [Phase 2] + roles.manage).
    * admin     — everything EXCEPT content.read and roles.manage.
    * moderator — users.view, users.moderate, audit.view.
    * support   — all *.view (read-only); no mutations, no content.read, no roles.manage.
    * user      — none.

  The session payload (see `AuthService.Sessions`) carries the user's `role` + resolved `permissions`
  (as strings — safe over the internal-API wire), so the gateway gate (`RequireAdmin` /
  `RequirePermission`) and, later, the frontend read them directly. `is_admin` is derived here
  (`admin?/1`) for backward-compat with the existing gate + frontend.
  """

  # Every permission the system knows about. `content.read` is DEFINED for Phase 2 (root only) but no
  # endpoint reads chat content yet.
  @permissions ~w(
    platform.view
    users.view
    users.moderate
    content.read
    apps.view
    keys.view
    webhooks.view
    webhooks.manage
    audit.view
    roles.manage
    users.delete
  )

  # Console roles (can reach /api/v1/admin at all), most→least privileged. `user` is excluded.
  @console_roles ~w(root admin moderator support)
  @all_roles @console_roles ++ ["user"]

  # Roles that map to the legacy is_admin flag.
  @admin_roles ~w(root admin)

  @support_view ~w(platform.view users.view apps.view keys.view webhooks.view audit.view)

  @role_permissions %{
    "root" => @permissions,
    # users.delete is ROOT-ONLY (permanent identity deletion) — excluded from admin alongside content.read
    # and roles.manage.
    "admin" => @permissions -- ["content.read", "roles.manage", "users.delete"],
    "moderator" => ~w(users.view users.moderate audit.view),
    "support" => @support_view,
    "user" => []
  }

  @doc "All known roles, most→least privileged."
  @spec roles() :: [String.t()]
  def roles, do: @all_roles

  @doc "All known permissions."
  @spec permissions() :: [String.t()]
  def permissions, do: @permissions

  @doc "Whether `role` is a valid role name."
  @spec valid_role?(term()) :: boolean()
  def valid_role?(role), do: to_string(role) in @all_roles

  # Hierarchy rank (higher = more privileged). Used for the moderation guard: you may only act on a
  # STRICTLY lower-ranked target.
  @role_ranks %{"root" => 4, "admin" => 3, "moderator" => 2, "support" => 1, "user" => 0}

  @doc "Numeric hierarchy rank for `role` (root=4 … user=0; unknown/nil → 0)."
  @spec rank(term()) :: non_neg_integer()
  def rank(role), do: Map.get(@role_ranks, normalize(role), 0)

  @doc "Whether an actor of `actor_role` may moderate a target of `target_role` (strictly higher rank)."
  @spec can_moderate?(term(), term()) :: boolean()
  def can_moderate?(actor_role, target_role), do: rank(actor_role) > rank(target_role)

  @doc "The permission list (strings) granted to `role`. Unknown/nil → []."
  @spec permissions_for(term()) :: [String.t()]
  def permissions_for(role), do: Map.get(@role_permissions, normalize(role), [])

  @doc "Whether `role` can reach the admin console at all (any admin role)."
  @spec console_access?(term()) :: boolean()
  def console_access?(role), do: normalize(role) in @console_roles

  @doc "Whether `role` maps to the legacy is_admin flag (root/admin). Derives is_admin in the session."
  @spec admin?(term()) :: boolean()
  def admin?(role), do: normalize(role) in @admin_roles

  @doc "Whether `role` grants `permission`."
  @spec has_permission?(term(), String.t()) :: boolean()
  def has_permission?(role, permission), do: permission in permissions_for(role)

  defp normalize(nil), do: "user"
  defp normalize(role), do: to_string(role)
end
