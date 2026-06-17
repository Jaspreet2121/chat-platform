defmodule AuthService.DeviceSessions do
  @moduledoc """
  Data-access boundary for per-device session persistence.
  """

  alias AuthService.Repo
  alias AuthService.Schemas.DeviceSession

  def device_session_changeset(attrs \\ %{}) do
    DeviceSession.changeset(%DeviceSession{}, attrs)
  end

  def create_device_session(attrs) do
    attrs
    |> device_session_changeset()
    |> Repo.insert()
  end

  def get_device_session(user_id, device_id) do
    Repo.get_by(DeviceSession, user_id: user_id, device_id: device_id)
  end

  def get_session(id), do: Repo.get(DeviceSession, id)

  def update_device_session(%DeviceSession{} = device_session, attrs) do
    device_session
    |> DeviceSession.changeset(attrs)
    |> Repo.update()
  end
end
