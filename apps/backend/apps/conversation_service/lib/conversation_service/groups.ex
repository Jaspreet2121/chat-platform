defmodule ConversationService.Groups do
  @moduledoc """
  Group conversation boundary.
  """

  @type group_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback get_group_profile(group_attrs()) :: result()

  def get_group_profile(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       name: Map.get(attrs, "name", "Launch Team"),
       description: Map.get(attrs, "description"),
       avatar_media_id: Map.get(attrs, "avatar_media_id")
     }}
  end
end
