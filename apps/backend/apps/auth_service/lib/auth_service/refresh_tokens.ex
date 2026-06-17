defmodule AuthService.RefreshTokens do
  @moduledoc """
  Data-access boundary for refresh token persistence.

  This stores token hashes only. Token generation and signing remain future work.
  """

  alias AuthService.Repo
  alias AuthService.Schemas.RefreshToken

  def refresh_token_changeset(attrs \\ %{}) do
    RefreshToken.changeset(%RefreshToken{}, attrs)
  end

  def create_refresh_token(attrs) do
    attrs
    |> refresh_token_changeset()
    |> Repo.insert()
  end

  def get_refresh_token(id), do: Repo.get(RefreshToken, id)

  def get_by_token_hash(token_hash) do
    Repo.get_by(RefreshToken, token_hash: token_hash)
  end

  def revoke_refresh_token(%RefreshToken{} = refresh_token, attrs) do
    refresh_token
    |> RefreshToken.revoke_changeset(attrs)
    |> Repo.update()
  end
end
