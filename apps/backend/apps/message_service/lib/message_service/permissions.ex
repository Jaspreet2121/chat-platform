defmodule MessageService.Permissions do
  @moduledoc """
  Message permission boundary.

  This is placeholder-only. Real authorization will check authenticated user,
  conversation membership, tenant access, block state, and rate limits.
  """

  @type permission_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback authorize(permission_attrs()) :: result()

  def authorize(_attrs) do
    {:ok,
     %{
       authorized: true,
       reason: "placeholder"
     }}
  end
end
