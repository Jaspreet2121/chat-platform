defmodule AuthService.Devices do
  @moduledoc """
  Device registration and lookup boundary.
  """

  @type device_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback register_device(device_attrs()) :: result()
  @callback get_device(device_attrs()) :: result()
  @callback touch_device(device_attrs()) :: result()

  def register_device(_attrs), do: {:error, :not_implemented}

  def get_device(_attrs), do: {:error, :not_implemented}

  def touch_device(_attrs), do: {:error, :not_implemented}
end
