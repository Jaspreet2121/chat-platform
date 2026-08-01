defmodule ApiGatewayWeb.StoreUnavailableMappingTest do
  @moduledoc """
  THE MISSING TEST — what the gateway returns when the message store cannot answer.

  `MessageStore.execute/2` normalizes driver failures to `:message_store_unavailable`, with the
  comment "a store outage must be :message_store_unavailable (503 at the gateway)". That was half a
  fix: the atom was right, but every gateway clause matches `:message_unavailable`, and nothing
  mapped between them — so a store outage fell through to a catch-all 400 "Request body is invalid"
  on EVERY message endpoint. Measured, not reasoned: GET messages, GET starred and GET search all
  returned 400 before this.

  Search is the case that shipped to users, because the scylla_read stub returns
  `:message_store_unavailable` on every call — so the documented capability error
  (503 `search.unavailable`, "never a silent empty list") was in fact a 400 the web client swallowed
  into "No results".

  Nothing held this. The suite that looked like it did asserted only that the INTERNAL service
  returns a string containing "unavailable" — the gateway mapping it claimed to have verified was
  never exercised. This suite exercises the mapping itself, which is the thing that drifted.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SharedInfra.MessageClient

  defmodule AuthStub do
    @moduledoc false
    def current_session(_), do: {:ok, %{user_id: "u-1", app_id: "app-1"}}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(_), do: {:ok, %{conversation_id: "c-1"}}
  end

  # EXACTLY what the store returns during a Scylla outage, and what the search stub returns always.
  defmodule StoreOutageClient do
    @moduledoc false
    def list_messages(_attrs), do: {:error, :message_store_unavailable}
    def list_timeline(_attrs), do: {:error, :message_store_unavailable}
    def list_starred(_attrs), do: {:error, :message_store_unavailable}
    def search_messages(_attrs), do: {:error, :message_store_unavailable}
  end

  setup do
    keys = [:auth_client_adapter, :conversation_client_adapter, :message_client_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_persist = Application.get_env(:message_service, :message_persistence)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, StoreOutageClient)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      if prev_persist,
        do: Application.put_env(:message_service, :message_persistence, prev_persist),
        else: Application.delete_env(:message_service, :message_persistence)
    end)

    :ok
  end

  test "SEARCH: a store that cannot answer is 503 search.unavailable — never 400, never empty" do
    conn = get(%{"q" => "hello"}, &ApiGatewayWeb.SearchController.messages(&1, %{"q" => "hello"}))

    assert conn.status == 503

    assert %{"error" => %{"code" => "search.unavailable"}} = Jason.decode!(conn.resp_body)

    # And emphatically NOT a 200 with an empty list. A silent empty list tells the user their query
    # matched nothing, which is a different and false statement.
    refute conn.status == 200
  end

  test "the same mapping holds for the OTHER message endpoints, not just search" do
    # Search is where it shipped, but the mismatch was systemic: every one of these returned 400
    # during a store outage. A 400 tells a client "your request was malformed" and invites it to
    # stop retrying; 503 is the truth and is retryable.
    listing =
      get(%{}, &ApiGatewayWeb.MessageController.index(&1, %{"conversation_id" => "c-1"}))

    assert listing.status == 503

    starred = get(%{}, &ApiGatewayWeb.StarredController.index(&1, %{}))
    assert starred.status == 503
  end

  test "THE BOUNDARY ITSELF: the client normalizes the store atom to the caller's atom" do
    # The mapping lives in SharedInfra.MessageClient, deliberately: ~35 call sites code against
    # :message_unavailable, and one normalization cannot drift out of sync with itself the way 35
    # separate clauses can. Asserted here directly so the reason survives a refactor of any one
    # controller.
    assert MessageClient.search_messages(%{}) == {:error, :message_unavailable}
    assert MessageClient.list_starred(%{}) == {:error, :message_unavailable}
    assert MessageClient.list_messages(%{}) == {:error, :message_unavailable}
  end

  defp get(params, fun) do
    :get
    |> conn("/x", params)
    |> put_req_header("authorization", "Bearer t")
    |> fun.()
  end
end
