defmodule UserService.Settings do
  @moduledoc """
  User settings boundary.
  """

  @type settings_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback get_settings(settings_attrs()) :: result()

  def get_settings(_attrs), do: {:ok, placeholder_settings()}

  def placeholder_settings do
    %{
      locale: "en",
      timezone: "UTC"
    }
  end
end
