defmodule UserService.Privacy do
  @moduledoc """
  User privacy settings boundary.
  """

  @type privacy_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback get_privacy(privacy_attrs()) :: result()

  def get_privacy(_attrs), do: {:ok, placeholder_privacy()}

  def placeholder_privacy do
    %{
      last_seen_visibility: "contacts",
      profile_photo_visibility: "contacts",
      read_receipts_enabled: true
    }
  end
end
