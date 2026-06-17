defmodule MessageService.Timeline do
  @moduledoc """
  Message timeline read boundary.
  """

  @type timeline_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback list_messages(timeline_attrs()) :: result()

  def list_messages(attrs) do
    if MessageService.Messages.message_persistence_enabled?() do
      MessageService.Messages.list_messages(attrs)
    else
      placeholder_list_messages(attrs)
    end
  end

  defp placeholder_list_messages(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       messages: [
         %{
           message_id: "msg_placeholder",
           sender_user_id: "user_placeholder",
           message_type: "text",
           body: "Hello",
           status: "active",
           created_at: "2026-06-17T10:15:00Z"
         }
       ],
       next_cursor: nil
     }}
  end
end
