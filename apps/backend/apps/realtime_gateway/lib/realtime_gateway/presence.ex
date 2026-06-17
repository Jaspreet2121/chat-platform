defmodule RealtimeGateway.Presence do
  @moduledoc """
  Phoenix Presence boundary for realtime topics.

  This is local PubSub-backed Presence for the current slice. Cluster-wide
  deployment and Redis-backed presence reconstruction remain future work.
  """

  use Phoenix.Presence,
    otp_app: :realtime_gateway,
    pubsub_server: RealtimeGateway.PubSub
end
