defmodule MessageService.Reactions do
  @moduledoc """
  Message reaction boundary.
  """

  @type reaction_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback add_reaction(reaction_attrs()) :: result()

  def add_reaction(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       message_id: Map.get(attrs, "message_id", "msg_placeholder"),
       user_id: "user_placeholder",
       reaction: Map.get(attrs, "reaction", "thumbs_up"),
       created_at: "2026-06-17T10:35:00Z"
     }}
  end
end
