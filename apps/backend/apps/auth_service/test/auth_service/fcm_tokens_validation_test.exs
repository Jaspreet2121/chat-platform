defmodule AuthService.FcmTokensValidationTest do
  @moduledoc """
  Argument validation — rejected before any query runs, so this needs no database and stays in the
  default (Docker-free) test lane. Storage behaviour is `AuthService.FcmTokensTest`.
  """
  use ExUnit.Case, async: true

  alias AuthService.FcmTokens

  @user "61111111-1111-4111-8111-111111111111"
  @token "fcm-registration-token-aaaaaaaaaaaaaaaaaaaa"

  test "missing fields are rejected" do
    assert {:error, :invalid_request} =
             FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => ""})

    assert {:error, :invalid_request} = FcmTokens.upsert_token(%{"token" => @token})
    assert {:error, :invalid_request} = FcmTokens.delete_token(%{"user_id" => @user_a})
  end

  test "pruning an empty or junk list is a no-op, never a query" do
    assert {:ok, %{deleted: 0}} = FcmTokens.delete_tokens([])
    assert {:ok, %{deleted: 0}} = FcmTokens.delete_tokens([nil, ""])
  end
end
