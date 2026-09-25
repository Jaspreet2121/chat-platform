defmodule SharedInfra.IamSensitivePermissionTest do
  @moduledoc """
  `users.sensitive.view` — the Matches capability. Root and admin ONLY.

  It is separated from `users.view` deliberately: a moderator handling a report does not need to know
  who somebody matched with, and support never does. This pins that, because the cheapest way to
  break it later is to add the permission to a role bundle without noticing what it opens.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.IAM

  @sensitive "users.sensitive.view"

  test "root and admin hold it" do
    assert IAM.has_permission?("root", @sensitive)
    assert IAM.has_permission?("admin", @sensitive)
  end

  test "moderator and support do NOT — nor does an ordinary user" do
    refute IAM.has_permission?("moderator", @sensitive)
    refute IAM.has_permission?("support", @sensitive)
    refute IAM.has_permission?("user", @sensitive)
    refute IAM.has_permission?(nil, @sensitive)
  end

  test "moderator and support keep everything else they had — this is a new capability, not a re-cut" do
    assert IAM.has_permission?("moderator", "users.view")
    assert IAM.has_permission?("moderator", "users.moderate")
    assert IAM.has_permission?("moderator", "audit.view")
    assert IAM.has_permission?("support", "platform.view")
    assert IAM.has_permission?("support", "audit.view")
  end

  test "it is a real permission, in the declared set" do
    assert @sensitive in IAM.permissions()
  end
end
