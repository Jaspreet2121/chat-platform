defmodule ApiGatewayWeb.ProfilePaymentPresenterTest do
  @moduledoc """
  The 100 visibility rules at the presenter, no DB: the OWNER sees everything (incl. the merchant
  map and the QR media id); payment='contacts' shows the trio only to someone sharing a
  conversation; payment='nobody' hides it from everyone but the owner; business='nobody' hides the
  business block; profile_visibility itself NEVER reaches a non-owner. Hidden = the keys are
  DROPPED, indistinguishable from unset.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.ProfilePresenter

  @owner "11111111-1111-1111-1111-111111111111"
  @contact "22222222-2222-2222-2222-222222222222"
  @stranger "33333333-3333-3333-3333-333333333333"
  @app "44444444-4444-4444-8444-444444444444"

  defmodule SharesStub do
    @moduledoc false
    # The presenter's "contacts" rule: @contact shares a conversation with the owner; others don't.
    def shares_conversation?(%{"user_a" => a, "user_b" => b}) do
      contact = "22222222-2222-2222-2222-222222222222"
      {:ok, %{shares: contact in [a, b]}}
    end

    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}
  end

  defmodule PrivacyStub do
    @moduledoc false
    def get_privacy(_attrs), do: {:ok, %{profile_photo_visibility: "everyone"}}
  end

  defmodule MediaStub do
    @moduledoc false
    def get_download_url(%{"media_id" => id, "purpose" => purpose}),
      do: {:ok, %{download_url: "https://cdn.example/#{purpose}/#{id}"}}
  end

  setup do
    keys = [
      conversation_client_adapter: SharesStub,
      user_client_adapter: PrivacyStub,
      media_client_adapter: MediaStub
    ]

    prev = for {k, _} <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    for {k, v} <- keys, do: Application.put_env(:shared_infra, k, v)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end
    end)

    :ok
  end

  defp card(visibility \\ %{"payment" => "contacts", "business" => "everyone"}) do
    %{
      user_id: @owner,
      display_name: "Shop Owner",
      avatar_media_id: nil,
      avatar_object_key: nil,
      app_id: @app,
      bio: "hello",
      upi_id: "shop@okaxis",
      payment_name: "Sharma Stores",
      upi_qr_media_id: "qr-media-1",
      upi_merchant: %{"mc" => "5411"},
      address: "12 Market Rd",
      website: "https://sharma.example",
      business_email: "shop@sharma.example",
      business_hours: "9-9 daily",
      profile_visibility: visibility
    }
  end

  test "OWNER sees everything: merchant map, media id, visibility, and the presigned QR url" do
    presented = ProfilePresenter.present(@owner, @owner, card())

    assert presented.upi_id == "shop@okaxis"
    assert presented.upi_merchant == %{"mc" => "5411"}
    assert presented.upi_qr_media_id == "qr-media-1"
    assert presented.upi_qr_url == "https://cdn.example/message/qr-media-1"
    assert presented.profile_visibility["payment"] == "contacts"
  end

  test "payment=contacts: a conversation-sharing viewer gets the trio (+url), a stranger gets NOTHING" do
    seen = ProfilePresenter.present(@contact, @owner, card())
    assert seen.upi_id == "shop@okaxis"
    assert seen.payment_name == "Sharma Stores"
    assert seen.upi_qr_url == "https://cdn.example/message/qr-media-1"
    # Owner-only internals never reach ANY viewer.
    refute Map.has_key?(seen, :upi_merchant)
    refute Map.has_key?(seen, :upi_qr_media_id)
    refute Map.has_key?(seen, :profile_visibility)

    hidden = ProfilePresenter.present(@stranger, @owner, card())
    refute Map.has_key?(hidden, :upi_id)
    refute Map.has_key?(hidden, :payment_name)
    refute Map.has_key?(hidden, :upi_qr_url)
    # The business block rides its own (default everyone) rule.
    assert hidden.address == "12 Market Rd"
  end

  test "payment=nobody hides the trio even from a contact; payment=everyone shows a stranger" do
    nobody = ProfilePresenter.present(@contact, @owner, card(%{"payment" => "nobody"}))
    refute Map.has_key?(nobody, :upi_id)

    everyone = ProfilePresenter.present(@stranger, @owner, card(%{"payment" => "everyone"}))
    assert everyone.upi_id == "shop@okaxis"
  end

  test "business=nobody hides address/website/email/hours from viewers, never from the owner" do
    visibility = %{"payment" => "everyone", "business" => "nobody"}

    viewer = ProfilePresenter.present(@stranger, @owner, card(visibility))
    refute Map.has_key?(viewer, :address)
    refute Map.has_key?(viewer, :website)
    refute Map.has_key?(viewer, :business_email)
    refute Map.has_key?(viewer, :business_hours)
    # Payment stayed independent.
    assert viewer.upi_id == "shop@okaxis"

    owner = ProfilePresenter.present(@owner, @owner, card(visibility))
    assert owner.address == "12 Market Rd"
  end

  test "a card WITHOUT payment fields (search rows) passes through untouched — nothing invented" do
    bare = %{user_id: @owner, display_name: "X", app_id: @app, avatar_media_id: nil}
    presented = ProfilePresenter.present(@stranger, @owner, bare)
    refute Map.has_key?(presented, :upi_id)
    refute Map.has_key?(presented, :upi_qr_url)
  end
end
