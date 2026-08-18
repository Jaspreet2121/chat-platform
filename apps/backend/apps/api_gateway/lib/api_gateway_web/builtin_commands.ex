defmodule ApiGatewayWeb.BuiltinCommands do
  @moduledoc """
  The static built-in slash commands (100). `requires` names the profile field that must be set for
  the command to appear — clients hide it (and deep-link to profile setup) until then. Templates
  resolve CLIENT-SIDE from the caller's own profile; `/qr` sends the generated UPI QR media. Nothing
  here touches the send path.

  `names/0` doubles as the RESERVED list for custom quick replies — a user can never shadow a
  built-in.
  """

  @commands [
    %{name: "qr", kind: "action", label: "Send my UPI QR", requires: "upi_id"},
    %{name: "pay", kind: "text", template: "Pay me on UPI: {upi_id}", requires: "upi_id"},
    %{name: "location", kind: "action", label: "Share live location"},
    %{name: "address", kind: "text", template: "{address}", requires: "address"},
    %{name: "website", kind: "text", template: "{website}", requires: "website"},
    %{name: "email", kind: "text", template: "{business_email}", requires: "business_email"},
    %{name: "hours", kind: "text", template: "{business_hours}", requires: "business_hours"},
    %{name: "contact", kind: "action", label: "Send my contact card"}
  ]

  @names Enum.map(@commands, & &1.name)

  def all, do: @commands
  def names, do: @names
  def reserved?(shortcut), do: shortcut in @names
end
